#pragma clang diagnostic ignored "-Wunguarded-availability"

/**
 * @file hello.c
 * @brief Hello world interface VLC module example
 */
#ifdef HAVE_CONFIG_H
# include "config.h"
#endif

#import "core_bluetooth_peripheral_server.h"
#include "jsonparser.h"

#include <stdlib.h>
#include <sys/stat.h>

/* VLC core API headers */
#include <vlc_common.h>
#include <vlc_plugin.h>
#include <vlc_interface.h>
#include <vlc_playlist.h>
#include <vlc_input.h>
#include <vlc_url.h>

#include <vlc_network.h>

#if defined(PF_UNIX) && !defined(PF_LOCAL)
#    define PF_LOCAL PF_UNIX
#endif

#if defined(AF_LOCAL) && ! defined(_WIN32)
#    include <sys/un.h>
#endif

#define MAX_LINE_LENGTH 1024
#define CONFIG_FILE_NAME "config.json"

/* Forward declarations */
static int Open(vlc_object_t *);
static void Close(vlc_object_t *);
static int InitUnixSocket(intf_thread_t *p_intf, char *psz_unix_path, int **ppi_socket);
static void ExitUnixSocket(intf_thread_t *p_intf, char *psz_unix_path, int *pi_socket, int i_socket);
static void *Run( void *data );
static int  Quit( vlc_object_t *, char const *,
        vlc_value_t, vlc_value_t, void * );
static bool ReadCommand( intf_thread_t *p_intf, char *p_buffer, int *pi_size );
static int ReadConfig(intf_thread_t *p_intf, const char *config_file_name);
static void ProcessEvents(intf_thread_t *p_intf, int64_t video_time);

static int  Input( vlc_object_t *, char const *, vlc_value_t, vlc_value_t, void * );
static int InputEvent( vlc_object_t *p_this, char const *psz_cmd, 
        vlc_value_t oldval, vlc_value_t newval, void *p_data );
static void PositionChanged( intf_thread_t *p_intf, input_thread_t *p_input );

#define UNIX_TEXT N_("UNIX socket event output")
#define UNIX_LONGTEXT N_("Send event over a Unix socket rather than stdin.")

/* Module descriptor */
vlc_module_begin()
    set_shortname(N_("BLuetooth rsync"))
    set_description(N_("Sync video play by bluetooth"))
    set_capability("interface", 0)
    set_callbacks(Open, Close)
    set_category(CAT_INTERFACE)
    set_subcategory(SUBCAT_INTERFACE_CONTROL)
    add_string("serviceName", "Video_Position", "Service Name", "", false)
    add_string("serviceUUID", "7315D272-ACC3-443D-9214-017D6EAFAD50", "Service UUID", "", false)
    add_string("characteristicUUID", "64CF3C7A-AF89-4435-825E-A22D71ACE8EA", "CBCharacteristic UUID", "", false)
    add_string("rc-unix", "/usr/local/var/vlc_event", UNIX_TEXT, UNIX_LONGTEXT, false)
vlc_module_end ()

/*****************************************************************************
 * intf_sys_t, VLCGrowlDelegate
 *****************************************************************************/
@interface LXCBAppDelegate : NSObject <LXCBPeripheralServerDelegate>
{
    NSString *serviceName;
    intf_thread_t *interfaceThread;
}

@property (nonatomic, strong) LXCBPeripheralServer *peripheral;

- (id)initWithInterfaceThread:(intf_thread_t *)thread;
- (bool)sendMessage:(const NSString *)msg;

@end

struct intf_sys_t
{
    int *pi_socket_listen;
    int i_socket;
    char *psz_unix_path;
    char *psz_service_name;
    char *psz_service_uuid;
    char *psz_characteristic_uuid;

    vlc_mutex_t status_lock;
    vlc_thread_t thread;
    playlist_t *p_playlist;
    input_thread_t *p_input;

    LXCBAppDelegate *p_bluetooth_delegate;

    json_value *p_events;
    int64_t i64_last_time;

    pid_t pid_hud_video_player;
};
/* Internal state for an instance of the module */

static int StartHUDVideoPlayer(intf_thread_t *p_intf)
{
    pid_t processId;
    if ((processId = fork()) == 0) {
        char app[] = "/usr/local/bin/ffplay";
        char * const argv[] = { app,
            "/usr/local/share/bg.png", NULL };
        if (execv(app, argv) < 0) {
            msg_Err(p_intf, "execv error when start HUD video player");
        }
    } else if (processId < 0) {
        msg_Err(p_intf, "fork error when start HUD video player");
    } else {
        p_intf->p_sys->pid_hud_video_player = processId;
        return VLC_SUCCESS;
    }
    return VLC_EGENERIC;
}

/**
 * Starts our example interface.
 */
static int Open(vlc_object_t *obj)
{
    intf_thread_t *p_intf = (intf_thread_t *)obj;
    msg_Info(p_intf, "Hello with bluetooth rsync plugin.");
    playlist_t *p_playlist = pl_Get( p_intf );
    char *psz_service_name = NULL, *psz_unix_path = NULL;
    char *psz_service_uuid = NULL, *psz_characteristic_uuid = NULL;
    int  *pi_socket = NULL;

    /* Allocate internal state */
    intf_sys_t *p_sys = malloc(sizeof (*p_sys));
    if (unlikely(p_sys == NULL))
        return VLC_ENOMEM;
    p_intf->p_sys = p_sys;

    /* Read settings */
    psz_service_name = var_InheritString(p_intf, "serviceName");
    if (psz_service_name == NULL)
    {
        msg_Err(p_intf, "service name not defined");
        goto error;
    }

    psz_service_uuid = var_InheritString(p_intf, "serviceUUID");
    if (psz_service_uuid == NULL)
    {
        msg_Err(p_intf, "service uuid not defined");
        goto error;
    }

    psz_characteristic_uuid = var_InheritString(p_intf, "characteristicUUID");
    if (psz_characteristic_uuid == NULL)
    {
        msg_Err(p_intf, "characteristic uuid not defined");
        goto error;
    }

    psz_unix_path = var_InheritString(p_intf, "rc-unix" );
    if( psz_unix_path == NULL)
    {
        msg_Err(p_intf, "rc-unix not defined");
        goto error;
    }

    int i_ret = InitUnixSocket(p_intf, psz_unix_path, &pi_socket);
    if (i_ret != VLC_SUCCESS) {
        msg_Err(p_intf, "open unix socket failed with error %d", i_ret);
        goto error;
    }

    p_sys->p_bluetooth_delegate = [[LXCBAppDelegate alloc] initWithInterfaceThread:p_intf];
    if( !p_sys->p_bluetooth_delegate )
    {
        free(p_sys);
        free(psz_service_name);
        free(psz_service_uuid);
        free(psz_characteristic_uuid);
        ExitUnixSocket(p_intf, psz_unix_path, pi_socket, -1);
        free(psz_unix_path);
        msg_Err(p_intf, "create delegate application failed");
        return VLC_ENOMEM;
    }
    
    p_sys->pi_socket_listen = pi_socket;
    p_sys->i_socket = -1;
    p_sys->psz_unix_path = psz_unix_path;

    p_sys->psz_service_name = psz_service_name;
    p_sys->psz_service_uuid = psz_service_uuid;
    p_sys->psz_characteristic_uuid = psz_characteristic_uuid;
    p_sys->p_bluetooth_delegate.peripheral = [[LXCBPeripheralServer alloc] initWithDelegate:p_sys->p_bluetooth_delegate];
    p_sys->p_bluetooth_delegate.peripheral.serviceName = [NSString stringWithFormat:@"%s", psz_service_name];
    NSString *serviceUUID = [NSString stringWithFormat:@"%s", psz_service_uuid];
    p_sys->p_bluetooth_delegate.peripheral.serviceUUID = [CBUUID UUIDWithString:serviceUUID];
    NSString *characteristicUUID = [NSString stringWithFormat:@"%s", psz_characteristic_uuid];
    p_sys->p_bluetooth_delegate.peripheral.characteristicUUID = [CBUUID UUIDWithString:characteristicUUID];
    [p_sys->p_bluetooth_delegate.peripheral startAdvertising];

    p_sys->p_playlist = p_playlist;
    p_sys->p_input = NULL;

    p_sys->p_events = NULL;
    p_sys->i64_last_time = -1;
    p_sys->pid_hud_video_player = 0;

    vlc_mutex_init( &p_sys->status_lock );

    if( vlc_clone( &p_sys->thread, Run, p_intf, VLC_THREAD_PRIORITY_LOW ) )
        abort();

    if (StartHUDVideoPlayer(p_intf) != VLC_SUCCESS) {
        abort();
    }

    msg_Info(p_intf, "Bluetooth event interface initialized");

    return VLC_SUCCESS;

error:
    if (psz_service_name != NULL) {
        free(psz_service_name);
    }
    if (psz_service_uuid != NULL) {
        free(psz_service_uuid);
    }
    if (psz_characteristic_uuid != NULL) {
        free(psz_characteristic_uuid);
    }
    if (psz_unix_path != NULL) {
        free(psz_unix_path);
    }
    free(p_sys);
    return VLC_EGENERIC;    
}

/**
 * Stops the interface. 
 */
static void Close(vlc_object_t *obj)
{
    intf_thread_t *p_intf = (intf_thread_t *)obj;
    intf_sys_t *p_sys = p_intf->p_sys;

    if (p_sys->pid_hud_video_player != 0) {
        kill(p_sys->pid_hud_video_player, SIGKILL);
    }

    vlc_cancel( p_sys->thread );
    vlc_join( p_sys->thread, NULL );

    if( p_sys->p_input != NULL )
    {
        var_DelCallback( p_sys->p_input, "intf-event", InputEvent, p_intf );
        vlc_object_release( p_sys->p_input );
    }

    /* Free internal state */
    [p_sys->p_bluetooth_delegate.peripheral release];
    [p_sys->p_bluetooth_delegate release];
    if (p_sys->psz_service_name != NULL) {
        free(p_sys->psz_service_name);
    }
    if (p_sys->psz_service_uuid != NULL) {
        free(p_sys->psz_service_uuid);
    }
    if (p_sys->psz_characteristic_uuid != NULL) {
        free(p_sys->psz_characteristic_uuid);
    }

    ExitUnixSocket(p_intf, p_sys->psz_unix_path, p_sys->pi_socket_listen, p_sys->i_socket);
    if (p_sys->psz_unix_path != NULL) {
        free(p_sys->psz_unix_path);
    }

    if (p_intf->p_sys->p_events != NULL) {
        json_value_free(p_intf->p_sys->p_events);
        p_intf->p_sys->p_events = NULL;
    }

    vlc_mutex_destroy( &p_sys->status_lock );
    free(p_sys);
}

static int InitUnixSocket(intf_thread_t *p_intf, char *psz_unix_path, int **ppi_socket)
{
    int i_socket;

#ifndef AF_LOCAL
    msg_Warn( p_intf, "your OS doesn't support filesystem sockets" );
    return VLC_EGENERIC;
#else
    struct sockaddr_un addr;

    memset( &addr, 0, sizeof(struct sockaddr_un) );

    msg_Dbg( p_intf, "trying UNIX socket" );

    if( (i_socket = vlc_socket( PF_LOCAL, SOCK_STREAM, 0, false ) ) < 0 )
    {
        msg_Warn( p_intf, "can't open socket: %s", vlc_strerror_c(errno) );
        return VLC_EGENERIC;
    }

    addr.sun_family = AF_LOCAL;
    strncpy( addr.sun_path, psz_unix_path, sizeof( addr.sun_path ) );
    addr.sun_path[sizeof( addr.sun_path ) - 1] = '\0';

    if (bind (i_socket, (struct sockaddr *)&addr, sizeof (addr))
            && (errno == EADDRINUSE)
            && connect (i_socket, (struct sockaddr *)&addr, sizeof (addr))
            && (errno == ECONNREFUSED))
    {
        msg_Info (p_intf, "Removing dead UNIX socket: %s", psz_unix_path);
        unlink (psz_unix_path);

        if (bind (i_socket, (struct sockaddr *)&addr, sizeof (addr)))
        {
            msg_Err (p_intf, "cannot bind UNIX socket at %s: %s",
                    psz_unix_path, vlc_strerror_c(errno));
            net_Close (i_socket);
            return VLC_EGENERIC;
        }
    }

    if( listen( i_socket, 1 ) )
    {
        msg_Warn (p_intf, "can't listen on socket: %s",
                vlc_strerror_c(errno));
        net_Close( i_socket );
        return VLC_EGENERIC;
    }

    /* FIXME: we need a core function to merge listening sockets sets */
    *ppi_socket = calloc( 2, sizeof( int ) );
    if( *ppi_socket == NULL )
    {
        msg_Err(p_intf, "calloc memory for listen socket failed");
        net_Close( i_socket );
        return VLC_ENOMEM;
    }
    (*ppi_socket)[0] = i_socket;
    (*ppi_socket)[1] = -1;
    return VLC_SUCCESS;
#endif /* AF_LOCAL */
}

static void ExitUnixSocket(intf_thread_t *p_intf, char *psz_unix_path, int *pi_socket, int i_socket)
{
    net_ListenClose(pi_socket);
    if(i_socket != -1)
        net_Close(i_socket);
    if(psz_unix_path != NULL)
    {
#if defined(AF_LOCAL) && !defined(_WIN32)
        unlink(psz_unix_path );
#endif
    }
}

/*****************************************************************************
 * RegisterCallbacks: Register callbacks to dynamic variables
 *****************************************************************************/
static void RegisterCallbacks( intf_thread_t *p_intf )
{
    /* Register commands that will be cleaned up upon object destruction */
#define ADD( name, type, target )                                   \
    var_Create( p_intf, name, VLC_VAR_ ## type | VLC_VAR_ISCOMMAND ); \
    var_AddCallback( p_intf, name, target, NULL );
    ADD( "quit", VOID, Quit )
#undef ADD
}

static void SetNonblocking(intf_thread_t *p_intf, int i_socket)
{
    int opts = fcntl(i_socket, F_GETFL);
    if (opts >= 0) {
        opts = opts | O_NONBLOCK;
        if (fcntl(i_socket, F_SETFL, opts) < 0) {
            msg_Err(p_intf, " fcntl(sock,SETFL,opts) failed ");
        }
    }
}

/*****************************************************************************
 * Run: rc thread
 *****************************************************************************
 * This part of the interface is in a separate thread so that we can call
 * exec() from within it without annoying the rest of the program.
 *****************************************************************************/
static void *Run( void *data )
{
    intf_thread_t *p_intf = data;
    intf_sys_t *p_sys = p_intf->p_sys;

    char p_buffer[ MAX_LINE_LENGTH + 1 ];

    int i_size = 0;
    int count = 0;
    int  canc = vlc_savecancel( );
    p_buffer[0] = 0;

    /* Register commands that will be cleaned up upon object destruction */
    RegisterCallbacks( p_intf );

    for ( ;; ) {
        msg_Info(p_intf, "loop...");
        char *psz_cmd = NULL;
        bool b_complete;

        vlc_restorecancel( canc );
        if( p_sys->pi_socket_listen != NULL && p_sys->i_socket == -1 )
        {
            p_sys->i_socket =
                net_Accept( p_intf, p_sys->pi_socket_listen );
            if( p_sys->i_socket == -1 ) continue;
            SetNonblocking(p_intf, p_sys->i_socket);
        }

        b_complete = ReadCommand( p_intf, p_buffer, &i_size );
        canc = vlc_savecancel( );

        /* Manage the input part */
        if( p_sys->p_input == NULL )
        {
            p_sys->p_input = playlist_CurrentInput( p_sys->p_playlist );
            /* New input has been registered */
            if( p_sys->p_input )
            {
                char *psz_uri = input_item_GetURI( input_GetItem( p_sys->p_input ) );
                msg_Info(p_intf, "( new input: %s )", psz_uri );
                if (psz_uri != NULL) {
                    char *psz_path = vlc_uri2path(psz_uri); 
                    if (psz_path != NULL) {
                        int length = strlen(psz_path);
                        char *psz_config_uri = (char *)malloc(length + 5);
                        if (psz_config_uri != NULL) {
                            strcpy(psz_config_uri, psz_path);
                            for (int i = length - 1; i > 0; i--) {
                                if (psz_config_uri[i] == '.') {
                                    psz_config_uri[i + 1] = '\0';
                                    break;
                                }
                            }
                            strcat(psz_config_uri , "json");
                            msg_Info(p_intf, "( new config: %s )", psz_config_uri);
                            vlc_mutex_lock( &p_intf->p_sys->status_lock );
                            p_sys->i64_last_time = -1;
                            ReadConfig(p_intf, psz_config_uri);
                            vlc_mutex_unlock( &p_intf->p_sys->status_lock );
                            free(psz_config_uri);
                        }
                        free(psz_path);
                    }
                    free( psz_uri );
                }

                var_AddCallback( p_sys->p_input, "intf-event", InputEvent, p_intf );
            }
        }

        int state;
        if( p_sys->p_input != NULL) {
            state = var_GetInteger(p_sys->p_input, "state");
            if (state == ERROR_S || state == END_S) {
                var_DelCallback( p_sys->p_input, "intf-event", InputEvent, p_intf );
                vlc_object_release( p_sys->p_input );
                p_sys->p_input = NULL;

                //p_sys->i_last_state = PLAYLIST_STOPPED;
                msg_Info(p_intf, "( stop state: 0 )" );
            }
        }

        /* Is there something to do? */
        if( !b_complete ) {
            usleep(200000);
            continue;
        }

        /* Skip heading spaces */
        psz_cmd = p_buffer;
        while( *psz_cmd == ' ' )
        {
            psz_cmd++;
        }

        if( !strcmp( psz_cmd, "logout" ) )
        {
            /* Close connection */
            if( p_sys->i_socket != -1 )
            {
                net_Close( p_sys->i_socket );
                p_sys->i_socket = -1;
            }
        }

        /* Command processed */
        i_size = 0; p_buffer[0] = 0;

        NSString *message = [NSString stringWithFormat:@"%s %d\n", "Time to go!", count++];
        [p_sys->p_bluetooth_delegate.peripheral sendToSubscribers:[message dataUsingEncoding:NSUTF8StringEncoding]];
    }

    msg_Info(p_intf, "( stop state: 0 )" );
    msg_Info(p_intf, "( quit )" );

    vlc_restorecancel( canc );

    return NULL;
}

static int Quit( vlc_object_t *p_this, char const *psz_cmd,
        vlc_value_t oldval, vlc_value_t newval, void *p_data )
{
    VLC_UNUSED(p_data); VLC_UNUSED(psz_cmd);
    VLC_UNUSED(oldval); VLC_UNUSED(newval);

    libvlc_Quit( p_this->obj.libvlc );
    return VLC_SUCCESS;
}

bool ReadCommand( intf_thread_t *p_intf, char *p_buffer, int *pi_size )
{
#if defined(_WIN32) && !VLC_WINSTORE_APP
    if( p_intf->p_sys->i_socket == -1 && !p_intf->p_sys->b_quiet )
        return ReadWin32( p_intf, p_buffer, pi_size );
    else if( p_intf->p_sys->i_socket == -1 )
    {
        msleep( INTF_IDLE_SLEEP );
        return false;
    }
#endif

    while( *pi_size < MAX_LINE_LENGTH )
    {
        if( p_intf->p_sys->i_socket == -1 )
        {
            if( read( 0/*STDIN_FILENO*/, p_buffer + *pi_size, 1 ) <= 0 )
            {   /* Standard input closed: exit */
                libvlc_Quit( p_intf->obj.libvlc );
                p_buffer[*pi_size] = 0;
                return true;
            }
        }
        else
        {   /* Connection closed */
            if( read( p_intf->p_sys->i_socket, p_buffer + *pi_size,
                          1 ) <= 0 )
            {
                 if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    return false;
                 } else {
                     net_Close( p_intf->p_sys->i_socket );
                     p_intf->p_sys->i_socket = -1;
                     p_buffer[*pi_size] = 0;
                     return true;
                 }
            }
        }

        if( p_buffer[ *pi_size ] == '\r' || p_buffer[ *pi_size ] == '\n' )
            break;

        (*pi_size)++;
    }

    if( *pi_size == MAX_LINE_LENGTH ||
        p_buffer[ *pi_size ] == '\r' || p_buffer[ *pi_size ] == '\n' )
    {
        p_buffer[ *pi_size ] = 0;
        return true;
    }

    return false;
}

static int InputEvent( vlc_object_t *p_this, char const *psz_cmd,
        vlc_value_t oldval, vlc_value_t newval, void *p_data )
{
    VLC_UNUSED(psz_cmd);
    VLC_UNUSED(oldval);
    input_thread_t *p_input = (input_thread_t*)p_this;
    intf_thread_t *p_intf = p_data;

    switch( newval.i_int ) {
         case INPUT_EVENT_POSITION:
            PositionChanged( p_intf, p_input );
            break;
         default:
            break;
    }
    return VLC_SUCCESS;
}

static void PositionChanged( intf_thread_t *p_intf,
        input_thread_t *p_input )
{
    vlc_mutex_lock( &p_intf->p_sys->status_lock );
    int64_t video_time = var_GetInteger(p_input, "time") / CLOCK_FREQ;
    if (p_intf->p_sys->i64_last_time != video_time) {
        msg_Info(p_intf, "( time: %"PRId64"s )", video_time );
        p_intf->p_sys->i64_last_time = video_time;
        ProcessEvents(p_intf, video_time);
    }
    vlc_mutex_unlock( &p_intf->p_sys->status_lock );
}

static int ReadConfig(intf_thread_t *p_intf, const char *config_file_name)
{
    FILE *fp;
    struct stat filestatus;
    int file_size;
    char* file_contents;
    json_char* json;

    if (p_intf->p_sys->p_events != NULL) {
        json_value_free(p_intf->p_sys->p_events);
        p_intf->p_sys->p_events = NULL;
    }

    if ( stat(config_file_name, &filestatus) != 0) {
        msg_Err(p_intf, "File %s not found\n", config_file_name);
        return VLC_EGENERIC;
    }
    file_size = filestatus.st_size;
    file_contents = (char*)malloc(filestatus.st_size);
    if ( file_contents == NULL) {
        msg_Err(p_intf, "Memory error: unable to allocate %d bytes\n", file_size);
        return VLC_EGENERIC;
    }

    fp = fopen(config_file_name, "rt");
    if (fp == NULL) {
        msg_Err(p_intf, "Unable to open %s\n", config_file_name);
        free(file_contents);
        return VLC_EGENERIC;
    }
    if ( fread(file_contents, file_size, 1, fp) != 1 ) {
        msg_Err(p_intf, "Unable t read content of %s\n", config_file_name);
        fclose(fp);
        free(file_contents);
        return VLC_EGENERIC;
    }
    fclose(fp);

    msg_Info(p_intf, "%s\n", file_contents);

    json = (json_char*)file_contents;

    p_intf->p_sys->p_events = json_parse(json, file_size);

    if (p_intf->p_sys->p_events == NULL) {
        msg_Err(p_intf, "Unable to parse data\n");
        return VLC_EGENERIC;
    }

    free(file_contents);
    return VLC_SUCCESS;
}

static void ProcessObject(intf_thread_t *p_intf, json_value* value)
{
    int length, x;
    if (value == NULL) {
        return;
    }
    length = value->u.object.length;
    for (x = 0; x < length; x++) {
        msg_Info(p_intf, "object[%d].name = %s", x, value->u.object.values[x].name);
        ProcessEvents(p_intf, value->u.object.values[x].value);
    }
}

static void ProcessArray(intf_thread_t *p_intf, json_value* value)
{
    int length, x;
    if (value == NULL) {
        return;
    }
    length = value->u.array.length;
    msg_Info(p_intf, "array");
    for (x = 0; x < length; x++) {
        ProcessEvents(p_intf, value->u.array.values[x]);
    }
}

static void ProcessEvents(intf_thread_t *p_intf, int64_t video_time)
{
    if (p_intf->p_sys->p_events == NULL) {
        return;
    }
    json_value *value = p_intf->p_sys->p_events;
    int j;
    switch (value->type) {
        case json_none:
            msg_Info(p_intf, "none");
            break;
        case json_object:
            ProcessObject(p_intf, value);
            break;
        case json_array:
            ProcessArray(p_intf, value);
            break;
        case json_integer:
            msg_Info(p_intf, "int: %10" PRId64, value->u.integer);
            break;
        case json_double:
            msg_Info(p_intf, "double: %f", value->u.dbl);
            break;
        case json_string:
            msg_Info(p_intf, "string: %s", value->u.string.ptr);
            break;
        case json_boolean:
            msg_Info(p_intf, "bool: %d", value->u.boolean);
            break;
    }
}

@implementation LXCBAppDelegate

- (id)initWithInterfaceThread:(intf_thread_t *)thread {
    if( !( self = [super init] ) )
        return nil;

    interfaceThread = thread;

    return self;
}

-(bool)sendMessage:(const NSString *)msg
{
    [self.peripheral sendToSubscribers:[msg dataUsingEncoding:NSUTF8StringEncoding]];
    return true;
}

#pragma mark - LXCBPeripheralServerDelegate
- (void)peripheralServer:(LXCBPeripheralServer *)peripheral centralDidSubscribe:(CBCentral *)central {
    [self.peripheral sendToSubscribers:[@"Hello" dataUsingEncoding:NSUTF8StringEncoding]];
    //[self.viewController centralDidConnect];
}

- (void)peripheralServer:(LXCBPeripheralServer *)peripheral centralDidUnsubscribe:(CBCentral *)central {
    //[self.viewController centralDidDisconnect];
}
@end
