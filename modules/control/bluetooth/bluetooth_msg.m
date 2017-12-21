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

/* Forward declarations */
static int Open(vlc_object_t *);
static void Close(vlc_object_t *);
static int InitUnixSocket(intf_thread_t *p_intf, char *psz_unix_path, int **ppi_socket);
static void ExitUnixSocket(intf_thread_t *p_intf, char *psz_unix_path, int *pi_socket, int i_socket);

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
