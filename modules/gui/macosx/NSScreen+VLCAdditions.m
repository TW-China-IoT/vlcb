/*****************************************************************************
 * NSScreen+VLCAdditions.m: Category with some additions to NSScreen
 *****************************************************************************
 * Copyright (C) 2003-2015 VLC authors and VideoLAN
 * $Id$
 *
 * Authors: Jon Lech Johansen <jon-vl@nanocrew.net>
 *          Felix Paul Kühne <fkuehne at videolan dot org>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/

#import "NSScreen+VLCAdditions.h"
#import "CompatibilityFixes.h"
#import "VLCMainWindow.h"
#import "VLCMain.h"

@implementation NSScreen (VLCAdditions)

static NSMutableArray *blackoutWindows = NULL;

static bool b_old_spaces_style = YES;

+ (void)load
{
    /* init our fake object attribute */
    blackoutWindows = [[NSMutableArray alloc] initWithCapacity:1];

    if (OSX_MAVERICKS_AND_HIGHER) {
        NSUserDefaults *userDefaults = [[NSUserDefaults alloc] init];
        [userDefaults addSuiteNamed:@"com.apple.spaces"];
        /* this is system settings -> mission control -> monitors using different spaces */
        NSNumber *o_span_displays = [userDefaults objectForKey:@"spans-displays"];

        b_old_spaces_style = [o_span_displays boolValue];
    }
}

+ (NSScreen *)screenWithDisplayID: (CGDirectDisplayID)displayID
{
    NSUInteger count = [[NSScreen screens] count];

    for ( NSUInteger i = 0; i < count; i++ ) {
        NSScreen *screen = [[NSScreen screens] objectAtIndex:i];
        if ([screen displayID] == displayID)
            return screen;
    }
    return nil;
}

- (BOOL)hasMenuBar
{
    if (b_old_spaces_style)
        return ([self displayID] == [[[NSScreen screens] firstObject] displayID]);
    else
        return YES;
}

- (BOOL)hasDock
{
    NSRect screen_frame = [self frame];
    NSRect screen_visible_frame = [self visibleFrame];
    CGFloat f_menu_bar_thickness = [self hasMenuBar] ? [[NSStatusBar systemStatusBar] thickness] : 0.0;

    BOOL b_found_dock = NO;
    if (screen_visible_frame.size.width < screen_frame.size.width)
        b_found_dock = YES;
    else if (screen_visible_frame.size.height + f_menu_bar_thickness < screen_frame.size.height)
        b_found_dock = YES;

    return b_found_dock;
}

- (BOOL)isScreen: (NSScreen*)screen
{
    return ([self displayID] == [screen displayID]);
}

- (CGDirectDisplayID)displayID
{
    return (CGDirectDisplayID)[[[self deviceDescription] objectForKey: @"NSScreenNumber"] intValue];
}

- (NSRect)autoSelectScreen
{
    NSUInteger screenCount = [[NSScreen screens] count];
    NSScreen *screen = [[NSScreen screens] objectAtIndex:screenCount - 1];
    NSRect screen_rect;

    screen_rect = [screen frame];
    int x = NSMinX(screen_rect);
    int y = NSMaxY(screen_rect);
    int w = NSWidth(screen_rect);
    int h = NSHeight(screen_rect);
    msg_Info(getIntf(), "screen x %d", x);
    msg_Info(getIntf(), "screen y %d", y);
    msg_Info(getIntf(), "screen w %d", w);
    msg_Info(getIntf(), "screen h %d", h);
    int hud_x = x;
    int hud_w = w;
    int hud_h = h / 4;
    int hud_y = h - hud_h;
    var_SetInteger(getIntf(), "hud-x", hud_x);
    var_SetInteger(getIntf(), "hud-y", hud_y);
    var_SetInteger(getIntf(), "hud-w", hud_w);
    var_SetInteger(getIntf(), "hud-h", hud_h);
    msg_Info(getIntf(), "hud-x %d", hud_x);
    msg_Info(getIntf(), "hud-y %d", hud_y);
    msg_Info(getIntf(), "hud-w %d", hud_w);
    msg_Info(getIntf(), "hud-h %d", hud_h);
    int player_x = x;
    int player_w = w;
    int player_h = h * 3 / 4;
    int player_y = y;
    msg_Info(getIntf(), "player-x %d", player_x);
    msg_Info(getIntf(), "player-y %d", player_y);
    msg_Info(getIntf(), "player-w %d", player_w);
    msg_Info(getIntf(), "player-h %d", player_h);
    return NSMakeRect(player_x, player_y, player_w, player_h);
}

- (void)blackoutOtherScreens
{
    /* Free our previous blackout window (follow blackoutWindow alloc strategy) */
    [blackoutWindows makeObjectsPerformSelector:@selector(close)];
    [blackoutWindows removeAllObjects];

    NSUInteger screenCount = [[NSScreen screens] count];
    for (NSUInteger i = 0; i < screenCount; i++) {
        NSScreen *screen = [[NSScreen screens] objectAtIndex:i];
        VLCWindow *blackoutWindow;
        NSRect screen_rect;

        if ([self isScreen: screen])
            continue;

        screen_rect = [screen frame];
        screen_rect.origin.x = screen_rect.origin.y = 0;

        /* blackoutWindow alloc strategy
         - The NSMutableArray blackoutWindows has the blackoutWindow references
         - blackoutOtherDisplays is responsible for alloc/releasing its Windows
         */
        blackoutWindow = [[VLCWindow alloc] initWithContentRect: screen_rect styleMask: NSBorderlessWindowMask
                                                        backing: NSBackingStoreBuffered defer: NO screen: screen];
        [blackoutWindow setBackgroundColor:[NSColor blackColor]];
        [blackoutWindow setLevel: NSFloatingWindowLevel]; /* Disappear when Expose is triggered */
        [blackoutWindow setReleasedWhenClosed:NO]; // window is released when deleted from array above

        [blackoutWindow displayIfNeeded];
        [blackoutWindow orderFront: self animate: YES];

        [blackoutWindows addObject: blackoutWindow];

        [screen setFullscreenPresentationOptions];
    }
}

+ (void)unblackoutScreens
{
    NSUInteger blackoutWindowCount = [blackoutWindows count];

    for (NSUInteger i = 0; i < blackoutWindowCount; i++) {
        VLCWindow *blackoutWindow = [blackoutWindows objectAtIndex:i];
        [[blackoutWindow screen] setNonFullscreenPresentationOptions];
        [blackoutWindow closeAndAnimate: YES];
    }
}

- (void)setFullscreenPresentationOptions
{
    NSApplicationPresentationOptions presentationOpts = [NSApp presentationOptions];
    if ([self hasMenuBar])
        presentationOpts |= NSApplicationPresentationAutoHideMenuBar;
    if ([self hasMenuBar] || [self hasDock])
        presentationOpts |= NSApplicationPresentationAutoHideDock;
    [NSApp setPresentationOptions:presentationOpts];
}

- (void)setNonFullscreenPresentationOptions
{
    NSApplicationPresentationOptions presentationOpts = [NSApp presentationOptions];
    if ([self hasMenuBar])
        presentationOpts &= (~NSApplicationPresentationAutoHideMenuBar);
    if ([self hasMenuBar] || [self hasDock])
        presentationOpts &= (~NSApplicationPresentationAutoHideDock);
    [NSApp setPresentationOptions:presentationOpts];
}


@end
