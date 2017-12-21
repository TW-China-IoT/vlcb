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

/* Forward declarations */
static int Open(vlc_object_t *);
static void Close(vlc_object_t *);
static int  ItemChange( vlc_object_t *, const char *,
        vlc_value_t, vlc_value_t, void * );

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

    /* Allocate internal state */
    intf_sys_t *p_sys = malloc(sizeof (*p_sys));
    if (unlikely(p_sys == NULL))
        return VLC_ENOMEM;
    p_intf->p_sys = p_sys;

    /* Read settings */
    char *psz_service_name = var_InheritString(p_intf, "serviceName");
    if (psz_service_name == NULL)
    {
        msg_Err(p_intf, "service name not defined");
        goto error;
    }

    p_sys->p_bluetooth_delegate = [[LXCBAppDelegate alloc] initWithInterfaceThread:p_intf];
    if( !p_sys->p_bluetooth_delegate )
    {
        free(p_sys);
        free(psz_service_name);
        msg_Err(p_intf, "create delegate application failed");
        return VLC_ENOMEM;
    }

    p_sys->psz_service_name = psz_service_name;
    p_sys->p_bluetooth_delegate.peripheral = [[LXCBPeripheralServer alloc] initWithDelegate:p_sys->p_bluetooth_delegate];
    p_sys->p_bluetooth_delegate.peripheral.serviceName = [NSString stringWithFormat:@"%s", psz_service_name];
    p_sys->p_bluetooth_delegate.peripheral.serviceUUID = [CBUUID UUIDWithString:@"7e57"];
    p_sys->p_bluetooth_delegate.peripheral.characteristicUUID = [CBUUID UUIDWithString:@"b71e"];
    [p_sys->p_bluetooth_delegate.peripheral startAdvertising];

    var_AddCallback( pl_Get( p_intf ), "item-change", &ItemChange, p_intf );

    return VLC_SUCCESS;

error:
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

    var_DelCallback( pl_Get(p_intf), "item-change", &ItemChange, p_intf );

    /* Free internal state */
    [p_sys->p_bluetooth_delegate.peripheral release];
    [p_sys->p_bluetooth_delegate release];
    if (p_sys->psz_service_name != NULL) {
        free(p_sys->psz_service_name);
    }
    free(p_sys);
}

static int ItemChange( vlc_object_t *p_this, const char *psz_var,
                       vlc_value_t oldval, vlc_value_t newval, void *param )
{
    VLC_UNUSED(psz_var);
    VLC_UNUSED(oldval);
    VLC_UNUSED(newval);

    int64_t i_time = 0LL;
    input_item_t *p_item = NULL;
    intf_thread_t *p_intf = (intf_thread_t *)param;
    char *psz_title = NULL;

    msg_Info(p_intf, "some item changed");

    playlist_Unlock( (playlist_t *)p_this );    /* playlist_CurrentInput hangs sometimes */
    input_thread_t *p_input = playlist_CurrentInput( (playlist_t *)p_this );

    if( !p_input )
        return VLC_SUCCESS;
    //if( p_input->b_dead )
    //{
        //vlc_object_release( p_input );
        //return VLC_SUCCESS;
    //}
    p_item = input_GetItem( p_input );
    if( !p_item || !p_item->psz_uri || !*p_item->psz_uri )
    {
        vlc_object_release( p_input );
        return VLC_SUCCESS;
    }
    /* Get title */
    psz_title = input_item_GetNowPlayingFb( p_item );
    if( !psz_title )
        psz_title = input_item_GetTitleFbName( p_item );

    if( EMPTY_STR( psz_title ) )
    {
        free( psz_title );
        return VLC_SUCCESS;
    }
    msg_Info(p_intf, psz_title);
    free(psz_title);

    if( VLC_SUCCESS == input_Control( p_input, INPUT_GET_TIME, &i_time) )
    {
        //TODO send new video position to central device
        char message[64] = "";
        sprintf(message, "%s %lld", "send position information", i_time);
        msg_Info(p_intf, message);
        //NSString *s_pos = [NSString stringWithFormat:@"%f", f_pos];
        //[p_intf->p_sys->bluetooth_delegate sendMessage:s_pos];
    }

    vlc_object_release( p_input );

    return VLC_SUCCESS;
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
