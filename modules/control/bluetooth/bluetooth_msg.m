#pragma clang diagnostic ignored "-Wunguarded-availability"

/**
 * @file hello.c
 * @brief Hello world interface VLC module example
 */
#ifdef HAVE_CONFIG_H
# include "config.h"
#endif

#import "core_bluetooth_peripheral_server.h"

#include <stdlib.h>
/* VLC core API headers */
#include <vlc_common.h>
#include <vlc_plugin.h>
#include <vlc_interface.h>
#include <vlc_playlist.h>
#include <vlc_input.h>

#include <vlc_network.h>

#if defined(PF_UNIX) && !defined(PF_LOCAL)
#    define PF_LOCAL PF_UNIX
#endif

#if defined(AF_LOCAL) && ! defined(_WIN32)
#    include <sys/un.h>
#endif

#define MAX_LINE_LENGTH 1024

/* Forward declarations */
static int Open(vlc_object_t *);
static void Close(vlc_object_t *);
static int InitUnixSocket(intf_thread_t *p_intf, char *psz_unix_path, int **ppi_socket);
static void ExitUnixSocket(intf_thread_t *p_intf, char *psz_unix_path, int *pi_socket, int i_socket);
static void *Run( void *data );
static int  Quit( vlc_object_t *, char const *,
        vlc_value_t, vlc_value_t, void * );
static bool ReadCommand( intf_thread_t *p_intf, char *p_buffer, int *pi_size );

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
    add_string("serviceUUID", "7e57", "Service UUID", "", false)
    add_string("characteristicUUID", "b71e", "CBCharacteristic UUID", "", false)
    add_string("rc-unix", "/usr/local/vlc_event", UNIX_TEXT, UNIX_LONGTEXT, false)
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

    vlc_thread_t thread;
    playlist_t *p_playlist;

    LXCBAppDelegate *p_bluetooth_delegate;
};
/* Internal state for an instance of the module */

/**
 * Starts our example interface.
 */
static int Open(vlc_object_t *obj)
{
    intf_thread_t *p_intf = (intf_thread_t *)obj;
    msg_Info(p_intf, "Hello with bluetooth rsync plugin.");
    playlist_t *p_playlist = pl_Get( p_intf );
    char *psz_service_name = NULL, *psz_unix_path = NULL;
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
        ExitUnixSocket(p_intf, psz_unix_path, pi_socket, -1);
        free(psz_unix_path);
        msg_Err(p_intf, "create delegate application failed");
        return VLC_ENOMEM;
    }
    
    p_sys->pi_socket_listen = pi_socket;
    p_sys->i_socket = -1;
    p_sys->psz_unix_path = psz_unix_path;

    p_sys->psz_service_name = psz_service_name;
    p_sys->p_bluetooth_delegate.peripheral = [[LXCBPeripheralServer alloc] initWithDelegate:p_sys->p_bluetooth_delegate];
    p_sys->p_bluetooth_delegate.peripheral.serviceName = [NSString stringWithFormat:@"%s", psz_service_name];
    p_sys->p_bluetooth_delegate.peripheral.serviceUUID = [CBUUID UUIDWithString:@"7e57"];
    p_sys->p_bluetooth_delegate.peripheral.characteristicUUID = [CBUUID UUIDWithString:@"b71e"];
    [p_sys->p_bluetooth_delegate.peripheral startAdvertising];

    p_sys->p_playlist = p_playlist;

    if( vlc_clone( &p_sys->thread, Run, p_intf, VLC_THREAD_PRIORITY_LOW ) )
        abort();

    msg_Info(p_intf, "Bluetooth event interface initialized");

    return VLC_SUCCESS;

error:
    if (psz_service_name != NULL) {
        free(psz_service_name);
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

    vlc_cancel( p_sys->thread );
    vlc_join( p_sys->thread, NULL );

    /* Free internal state */
    [p_sys->p_bluetooth_delegate.peripheral release];
    [p_sys->p_bluetooth_delegate release];
    if (p_sys->psz_service_name != NULL) {
        free(p_sys->psz_service_name);
    }

    ExitUnixSocket(p_intf, p_sys->psz_unix_path, p_sys->pi_socket_listen, p_sys->i_socket);
    if (p_sys->psz_unix_path != NULL) {
        free(p_sys->psz_unix_path);
    }
    free(p_sys);
}

//NSString *s_pos = [NSString stringWithFormat:@"%f", f_pos];
//[p_intf->p_sys->bluetooth_delegate sendMessage:s_pos];

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
    int  canc = vlc_savecancel( );
    p_buffer[0] = 0;

    /* Register commands that will be cleaned up upon object destruction */
    RegisterCallbacks( p_intf );

    for ( ;; ) {
        char *psz_cmd = NULL;
        bool b_complete;

        vlc_restorecancel( canc );
        if( p_sys->pi_socket_listen != NULL && p_sys->i_socket == -1 )
        {
            p_sys->i_socket =
                net_Accept( p_intf, p_sys->pi_socket_listen );
            if( p_sys->i_socket == -1 ) continue;
        }

        b_complete = ReadCommand( p_intf, p_buffer, &i_size );
        canc = vlc_savecancel( );

        /* Is there something to do? */
        if( !b_complete ) continue;

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
            if( net_Read( p_intf, p_intf->p_sys->i_socket, p_buffer + *pi_size,
                          1 ) <= 0 )
            {
                net_Close( p_intf->p_sys->i_socket );
                p_intf->p_sys->i_socket = -1;
                p_buffer[*pi_size] = 0;
                return true;
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
