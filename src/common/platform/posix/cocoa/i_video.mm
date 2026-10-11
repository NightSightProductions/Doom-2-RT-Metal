/*
 ** i_video.mm
 **
 **---------------------------------------------------------------------------
 ** Copyright 2012-2018 Alexey Lysiuk
 ** All rights reserved.
 **
 ** Redistribution and use in source and binary forms, with or without
 ** modification, are permitted provided that the following conditions
 ** are met:
 **
 ** 1. Redistributions of source code must retain the above copyright
 **    notice, this list of conditions and the following disclaimer.
 ** 2. Redistributions in binary form must reproduce the above copyright
 **    notice, this list of conditions and the following disclaimer in the
 **    documentation and/or other materials provided with the distribution.
 ** 3. The name of the author may not be used to endorse or promote products
 **    derived from this software without specific prior written permission.
 **
 ** THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
 ** IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 ** OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 ** IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
 ** INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 ** NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 ** DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 ** THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 ** (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 ** THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **---------------------------------------------------------------------------
 **
 */

#include "gl_load.h"

#ifdef HAVE_VULKAN
#include <zvulkan/vulkansurface.h>
#include <zvulkan/vulkanbuilders.h>
#endif

#include "i_common.h"

#include "v_video.h"
#include "bitmap.h"
#include "c_dispatch.h"
#include "hardware.h"
#include "i_system.h"
#include "m_argv.h"
#include "m_png.h"
#include "st_console.h"
#include "v_text.h"
#include "version.h"
#include "printf.h"
#include "gl_framebuffer.h"
#ifdef HAVE_GLES2
#include "gles_framebuffer.h"
#endif

#ifdef HAVE_VULKAN
#include "vulkan/system/vk_renderdevice.h"

bool I_CreateVulkanSurface(VkInstance instance, VkSurfaceKHR *surface);
#endif

#if HAVE_RT
#import <QuartzCore/CAMetalLayer.h>

#include <algorithm>
#include <vector>
#include "cmdlib.h"
#include "rt/rt_platform.h"
#endif

extern bool ToggleFullscreen;

@implementation NSWindow(ExitAppOnClose)

- (void)exitAppOnClose
{
	NSButton* closeButton = [self standardWindowButton:NSWindowCloseButton];
	[closeButton setAction:@selector(sendExitEvent:)];
	[closeButton setTarget:[NSApp delegate]];
}

@end

@interface NSWindow(EnterFullscreenOnZoom)
- (void)enterFullscreenOnZoom;
@end

@implementation NSWindow(EnterFullscreenOnZoom)

- (void)enterFullscreen:(id)sender
{
	ToggleFullscreen = true;
}

- (void)enterFullscreenOnZoom
{
	NSButton* zoomButton = [self standardWindowButton:NSWindowZoomButton];
	[zoomButton setEnabled:YES];
	[zoomButton setAction:@selector(enterFullscreen:)];
	[zoomButton setTarget:self];
}

@end

EXTERN_CVAR(Bool, vid_hidpi)
EXTERN_CVAR(Int,  vid_defwidth)
EXTERN_CVAR(Int,  vid_defheight)
EXTERN_CVAR(Bool, vk_debug)
#if HAVE_RT
EXTERN_CVAR(Bool, vid_metalhud)
void I_RT_ApplyMetalHUDOnCreate(CALayer* layer);
#endif

#if HAVE_RT
EXTERN_CVAR(Int, vid_rt_fullscreenwidth)
EXTERN_CVAR(Int, vid_rt_fullscreenheight)

// The view with RTGL1's CAMetalLayer, inside the window's content view (RTContainerView)
static NSView* s_rtView = nil;

NSView* I_RT_RenderView(const NSWindow* window)
{
	return s_rtView != nil && s_rtView.window == window ? s_rtView : [window contentView];
}

// Fullscreen: the chosen resolution (vid_rt_fullscreenwidth x vid_rt_fullscreenheight) is scaled to the screen,
// keeping its aspect ratio (black bars, if it's not the screen's), as Quake II RTX's display modes.
// Otherwise, the view fills the window, in the display's pixels.
static void I_RT_LayoutRenderView(NSWindow* window, bool fullscreen)
{
	if (s_rtView == nil || s_rtView.window != window)
	{
		return;
	}
	const NSRect  bounds  = [window contentView].bounds;
	const CGFloat backing = window.screen != nil ? window.screen.backingScaleFactor : window.backingScaleFactor;

	NSRect  frame = bounds;
	CGFloat scale = backing;

	if (fullscreen && vid_rt_fullscreenwidth > 0 && bounds.size.width > 0 && bounds.size.height > 0)
	{
		const CGFloat w = CGFloat(vid_rt_fullscreenwidth);
		const CGFloat h = vid_rt_fullscreenheight > 0
			? CGFloat(vid_rt_fullscreenheight)
			: w * bounds.size.height / bounds.size.width;

		// aspect-fit, centered
		const CGFloat fit = std::min(bounds.size.width / w, bounds.size.height / h);
		frame.size   = NSMakeSize(std::round(w * fit), std::round(h * fit));
		frame.origin = NSMakePoint(std::round((bounds.size.width - frame.size.width) / 2),
		                           std::round((bounds.size.height - frame.size.height) / 2));

		scale = std::clamp(w / frame.size.width, CGFloat(0.25), backing);
	}

	if (!NSEqualRects(s_rtView.frame, frame))
	{
		s_rtView.frame = frame;
	}
	if (s_rtView.layer.contentsScale != scale)
	{
		s_rtView.layer.contentsScale = scale;
	}
}
#endif

// Whether window sizes and the drawable are in the display's backing pixels.
// The RT renderer always uses pixels (as on other platforms): resolutions don't depend on vid_hidpi.
static bool I_UseBackingPixels()
{
#if HAVE_RT
	return true;
#else
	return vid_hidpi;
#endif
}

CVAR(Bool, mvk_debug, false, 0)
CVAR(Bool, vid_nativefullscreen, false, CVAR_ARCHIVE | CVAR_GLOBALCONFIG)

CUSTOM_CVAR(Bool, vid_autoswitch, true, CVAR_ARCHIVE | CVAR_GLOBALCONFIG | CVAR_NOINITCALL)
{
	Printf("You must restart " GAMENAME " to apply graphics switching mode\n");
}


// ---------------------------------------------------------------------------


namespace
{
	const NSInteger LEVEL_FULLSCREEN = NSMainMenuWindowLevel + 1;
	const NSInteger LEVEL_WINDOWED   = NSNormalWindowLevel;

	const NSUInteger STYLE_MASK_FULLSCREEN = NSWindowStyleMaskBorderless;
	const NSUInteger STYLE_MASK_WINDOWED   = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
}


// ---------------------------------------------------------------------------


@interface CocoaWindow : NSWindow
{
	NSString* m_title;
}

- (BOOL)canBecomeKeyWindow;
- (void)setTitle:(NSString*)title;
- (void)updateTitle;

@end


@implementation CocoaWindow

- (BOOL)canBecomeKeyWindow
{
	return true;
}

- (void)setTitle:(NSString*)title
{
	m_title = title;

	[self updateTitle];
}

- (void)updateTitle
{
	if (nil == m_title)
	{
		m_title = [NSString stringWithFormat:@"%s %s", GAMENAME, GetVersionString()];
	}

	[super setTitle:m_title];
}

- (void)frameDidChange:(NSNotification*)notification
{
	const NSRect frame = [self frame];
	win_x = frame.origin.x;
	win_y = frame.origin.y;
	win_w = frame.size.width;
	win_h = frame.size.height;
}

@end


// ---------------------------------------------------------------------------


@interface OpenGLCocoaView : NSOpenGLView
{
	NSCursor* m_cursor;
}

- (void)setCursor:(NSCursor*)cursor;

@end


@implementation OpenGLCocoaView

- (void)drawRect:(NSRect)dirtyRect
{
	if ([NSGraphicsContext currentContext])
	{
		[NSColor.blackColor setFill];
		NSRectFill(dirtyRect);
	}
	else if (self.layer != nil)
	{
		self.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
	}
}

- (void)resetCursorRects
{
	[super resetCursorRects];

	NSCursor* const cursor = nil == m_cursor
		? [NSCursor arrowCursor]
		: m_cursor;

	[self addCursorRect:[self bounds]
				 cursor:cursor];
}

- (void)setCursor:(NSCursor*)cursor
{
	m_cursor = cursor;
}

@end


// ---------------------------------------------------------------------------


@interface VulkanCocoaView : NSView
{
	NSCursor* m_cursor;
}

- (void)setCursor:(NSCursor*)cursor;

@end


@implementation VulkanCocoaView

- (void)resetCursorRects
{
	[super resetCursorRects];

	NSCursor* const cursor = nil == m_cursor
		? [NSCursor arrowCursor]
		: m_cursor;

	[self addCursorRect:[self bounds]
				 cursor:cursor];
}

- (void)setCursor:(NSCursor*)cursor
{
	m_cursor = cursor;
}

+(Class) layerClass
{
	return NSClassFromString(@"CAMetalLayer");
}

-(CALayer*) makeBackingLayer
{
	return [self.class.layerClass layer];
}

-(BOOL) isOpaque
{
	return YES;
}

@end


#if HAVE_RT
// The window's content view: keeps the render view laid out, see I_RT_LayoutRenderView
@interface RTContainerView : NSView
@end

@implementation RTContainerView

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize
{
	I_RT_LayoutRenderView(self.window, vid_fullscreen);
}

-(BOOL) isOpaque
{
	return YES;
}

@end
#endif


// ---------------------------------------------------------------------------


extern id appCtrl;


namespace
{

CocoaWindow* CreateWindow(const NSUInteger styleMask)
{
	CocoaWindow* const window = [CocoaWindow alloc];
	[window initWithContentRect:NSMakeRect(0, 0, vid_defwidth, vid_defheight)
					  styleMask:styleMask
						backing:NSBackingStoreBuffered
						  defer:NO];
	[window setOpaque:YES];
	[window makeFirstResponder:appCtrl];
	[window setAcceptsMouseMovedEvents:YES];
	[window exitAppOnClose];

	NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
	[nc addObserver:window
		   selector:@selector(frameDidChange:)
			   name:NSWindowDidEndLiveResizeNotification
			 object:nil];
	[nc addObserver:window
		   selector:@selector(frameDidChange:)
			   name:NSWindowDidMoveNotification
			 object:nil];

	return window;
}

enum class OpenGLProfile
{
	Core,
	Legacy
};

NSOpenGLPixelFormat* CreatePixelFormat(const OpenGLProfile profile)
{
	NSOpenGLPixelFormatAttribute attributes[16];
	size_t i = 0;

	attributes[i++] = NSOpenGLPFADoubleBuffer;
	attributes[i++] = NSOpenGLPFAColorSize;
	attributes[i++] = NSOpenGLPixelFormatAttribute(32);
	attributes[i++] = NSOpenGLPFADepthSize;
	attributes[i++] = NSOpenGLPixelFormatAttribute(24);
	attributes[i++] = NSOpenGLPFAStencilSize;
	attributes[i++] = NSOpenGLPixelFormatAttribute(8);

	if (profile == OpenGLProfile::Core)
	{
		attributes[i++] = NSOpenGLPFAOpenGLProfile;
		attributes[i++] = NSOpenGLProfileVersion3_2Core;
	}

	if (!vid_autoswitch)
	{
		attributes[i++] = NSOpenGLPFAAllowOfflineRenderers;
	}

	attributes[i] = NSOpenGLPixelFormatAttribute(0);

	assert(i < sizeof attributes / sizeof attributes[0]);

	return [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
}

void SetupOpenGLView(CocoaWindow* const window, const OpenGLProfile profile)
{
	NSOpenGLPixelFormat* pixelFormat = CreatePixelFormat(profile);

	if (nil == pixelFormat)
	{
		I_FatalError("Cannot create OpenGL pixel format, graphics hardware is not supported");
	}

	// Create OpenGL context and view

	const NSRect contentRect = [window contentRectForFrameRect:[window frame]];
	OpenGLCocoaView* glView = [[OpenGLCocoaView alloc] initWithFrame:contentRect
														 pixelFormat:pixelFormat];
	[[glView openGLContext] makeCurrentContext];

	[window setContentView:glView];
}

} // unnamed namespace


// ---------------------------------------------------------------------------


class CocoaVideo : public IVideo
{
public:
	CocoaVideo()
	{
		ms_isVulkanEnabled = V_GetBackend() == 1 && NSAppKitVersionNumber >= 1404; // NSAppKitVersionNumber10_11
	}

	~CocoaVideo()
	{
#ifdef HAVE_VULKAN
		m_vulkanSurface.reset();
#endif
		ms_window = nil;
	}

	virtual DFrameBuffer* CreateFrameBuffer() override
	{
		assert(ms_window == nil);
		ms_window = CreateWindow(STYLE_MASK_WINDOWED);

		const NSRect contentRect = [ms_window contentRectForFrameRect:[ms_window frame]];
		SystemBaseFrameBuffer *fb = nullptr;

#if HAVE_RT
		// RTGL1 renders with Metal: VulkanCocoaView is backed by a CAMetalLayer,
		// RTGL1 sets its device and pixel format, and follows its size
		NSView* container = [[RTContainerView alloc] initWithFrame:contentRect];
		container.wantsLayer = YES;
		container.layer.backgroundColor = NSColor.blackColor.CGColor;
		[ms_window setContentView:container];

		NSView* rtView = [[VulkanCocoaView alloc] initWithFrame:container.bounds];
		rtView.wantsLayer = YES;
		rtView.layer.backgroundColor = NSColor.blackColor.CGColor;
		[container addSubview:rtView];
		s_rtView = rtView;
		I_RT_LayoutRenderView(ms_window, vid_fullscreen);

		fb = static_cast<SystemBaseFrameBuffer*>(RT_CreateMetalFrameBuffer((__bridge void*)rtView.layer, vid_fullscreen));

		I_RT_ApplyMetalHUDOnCreate(rtView.layer);
#else
#ifdef HAVE_VULKAN
		if (ms_isVulkanEnabled)
		{
			NSView* vulkanView = [[VulkanCocoaView alloc] initWithFrame:contentRect];
			vulkanView.wantsLayer = YES;
			vulkanView.layer.backgroundColor = NSColor.blackColor.CGColor;

			[ms_window setContentView:vulkanView];

			// See vk_mvk_moltenvk.h for comprehensive explanation of configuration options set below
			// https://github.com/KhronosGroup/MoltenVK/blob/master/MoltenVK/MoltenVK/API/vk_mvk_moltenvk.h

			if (vk_debug)
			{
				// Output errors and informational messages
				setenv("MVK_CONFIG_LOG_LEVEL", "2", 0);

				if (mvk_debug)
				{
					// Extensive MoltenVK logging, too spammy even for vk_debug CVAR
					setenv("MVK_DEBUG", "1", 0);
				}
			}
			else
			{
				// Limit MoltenVK logging to errors only
				setenv("MVK_CONFIG_LOG_LEVEL", "1", 0);
			}

			if (!vid_autoswitch)
			{
				// CVAR from pre-Vulkan era has a priority over vk_device selection
				setenv("MVK_CONFIG_FORCE_LOW_POWER_GPU", "1", 0);
			}

			// The following settings improve performance like suggested at
			// https://github.com/KhronosGroup/MoltenVK/issues/581#issuecomment-487293665
			setenv("MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS", "0", 0);
			setenv("MVK_CONFIG_PRESENT_WITH_COMMAND_BUFFER", "0", 0);

			try
			{
				VulkanInstanceBuilder builder;
				builder.DebugLayer(vk_debug);
				builder.RequireExtension(VK_KHR_SURFACE_EXTENSION_NAME); // KHR_surface, required
				builder.OptionalExtension(VK_EXT_METAL_SURFACE_EXTENSION_NAME); // EXT_metal_surface, optional, preferred
				builder.OptionalExtension(VK_MVK_MACOS_SURFACE_EXTENSION_NAME); // MVK_macos_surface, optional, deprecated
				auto vulkanInstance = builder.Create();

				VkSurfaceKHR surfacehandle = nullptr;
				if (!I_CreateVulkanSurface(vulkanInstance->Instance, &surfacehandle))
					VulkanError("I_CreateVulkanSurface failed");

				m_vulkanSurface = std::make_shared<VulkanSurface>(vulkanInstance, surfacehandle);

				fb = new VulkanRenderDevice(nullptr, vid_fullscreen, m_vulkanSurface);
			}
			catch (std::exception const&)
			{
				ms_isVulkanEnabled = false;

				SetupOpenGLView(ms_window, OpenGLProfile::Core);
			}
		}
		else
#endif

		SetupOpenGLView(ms_window, OpenGLProfile::Core);

		if (fb == nullptr)
		{
#ifdef HAVE_GLES2
			if(V_GetBackend() != 0)
				fb = new OpenGLESRenderer::OpenGLFrameBuffer(0, vid_fullscreen);
			else
#endif
				fb = new OpenGLRenderer::OpenGLFrameBuffer(0, vid_fullscreen);
		}
#endif // HAVE_RT

		fb->SetWindow(ms_window);
		fb->SetMode(vid_fullscreen, vid_hidpi);
		fb->SetSize(fb->GetClientWidth(), fb->GetClientHeight());

#ifdef HAVE_VULKAN
		// This lame hack is a temporary workaround for strange performance issues
		// with fullscreen window and Core Animation's Metal layer
		// It is somehow related to initial window level and flags
		// Toggling fullscreen -> window -> fullscreen mysteriously solves the problem
		if (ms_isVulkanEnabled && vid_fullscreen)
		{
			fb->SetMode(false, vid_hidpi);
			fb->SetMode(true, vid_hidpi);
		}
#endif

		return fb;
	}

	static CocoaWindow* GetWindow()
	{
		return ms_window;
	}

private:
#ifdef HAVE_VULKAN
	std::shared_ptr<VulkanSurface> m_vulkanSurface;
#endif
	static CocoaWindow* ms_window;

	static bool ms_isVulkanEnabled;
};


CocoaWindow* CocoaVideo::ms_window;

bool CocoaVideo::ms_isVulkanEnabled;


// ---------------------------------------------------------------------------


static SystemBaseFrameBuffer* frameBuffer;


SystemBaseFrameBuffer::SystemBaseFrameBuffer(void*, const bool fullscreen)
: DFrameBuffer(vid_defwidth, vid_defheight)
, m_fullscreen(false)
, m_hiDPI(false)
, m_window(nullptr)
{
	assert(frameBuffer == nullptr);
	frameBuffer = this;

	FConsoleWindow::GetInstance().Show(false);
}

SystemBaseFrameBuffer::~SystemBaseFrameBuffer()
{
	assert(frameBuffer == this);
	frameBuffer = nullptr;

#if HAVE_RT
	// the same as Win32RTVideo::Shutdown in Windows' ~SystemBaseFrameBuffer
	RT_DestroyInstance();
#endif

	NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
	[nc removeObserver:m_window
				  name:NSWindowDidMoveNotification
				object:nil];
	[nc removeObserver:m_window
				  name:NSWindowDidEndLiveResizeNotification
				object:nil];
}

bool SystemBaseFrameBuffer::IsFullscreen()
{
	return m_fullscreen;
}

void SystemBaseFrameBuffer::ToggleFullscreen(bool yes)
{
	SetMode(yes, m_hiDPI);
}

void SystemBaseFrameBuffer::SetWindowSize(int width, int height)
{
	if (width < VID_MIN_WIDTH || height < VID_MIN_HEIGHT)
	{
		return;
	}

	if (vid_fullscreen)
	{
		// Enter windowed mode in order to calculate title bar height
		vid_fullscreen = false;
		SetMode(false, m_hiDPI);
	}

#if HAVE_RT
	// The resolution menu specifies pixels, as on other platforms:
	// with HiDPI, a window of width x height points would be rendered at backingScaleFactor times that
	if (I_UseBackingPixels() && m_window.screen != nil)
	{
		const CGFloat scale = m_window.screen.backingScaleFactor;
		width  = int(width / scale);
		height = int(height / scale);
	}
#endif

	win_w = width;
	win_h = height + GetTitleBarHeight();

	SetMode(false, m_hiDPI);

	[m_window center];
}

int SystemBaseFrameBuffer::GetTitleBarHeight() const
{
	const NSRect windowFrame = [m_window frame];
	const NSRect contentFrame = [m_window contentRectForFrameRect:windowFrame];
	const int titleBarHeight = windowFrame.size.height - contentFrame.size.height;

	return titleBarHeight;
}


int SystemBaseFrameBuffer::GetClientWidth()
{
	const int clientWidth = I_GetContentViewSize(m_window).width;
	return clientWidth > 0 ? clientWidth : GetWidth();
}

int SystemBaseFrameBuffer::GetClientHeight()
{
	const int clientHeight = I_GetContentViewSize(m_window).height;
	return clientHeight > 0 ? clientHeight : GetHeight();
}


void SystemBaseFrameBuffer::SetFullscreenMode()
{
	if (!m_fullscreen)
	{
		[m_window setLevel:LEVEL_FULLSCREEN];
		[m_window setStyleMask:STYLE_MASK_FULLSCREEN];

		[m_window setHidesOnDeactivate:YES];
	}

	const NSRect screenFrame = [[m_window screen] frame];
	[m_window setFrame:screenFrame display:YES];
}

void SystemBaseFrameBuffer::SetWindowedMode()
{
	if (m_fullscreen)
	{
		[m_window setLevel:LEVEL_WINDOWED];
		[m_window setStyleMask:STYLE_MASK_WINDOWED];

		[m_window setHidesOnDeactivate:NO];
	}

	const int minimumFrameWidth  = VID_MIN_WIDTH;
	const int minimumFrameHeight = VID_MIN_HEIGHT + GetTitleBarHeight();
	const NSSize minimumFrameSize = NSMakeSize(minimumFrameWidth, minimumFrameHeight);
	[m_window setMinSize:minimumFrameSize];

	const bool isFrameValid = win_x != -1 && win_y != -1
		&& win_w >= minimumFrameWidth && win_h >= minimumFrameHeight;

	if (!isFrameValid)
	{
		const NSRect screenSize = [[NSScreen mainScreen] frame];
		win_x = screenSize.origin.x + screenSize.size.width  / 10;
		win_y = screenSize.origin.y + screenSize.size.height / 10;
		win_w = screenSize.size.width  * 8 / 10;
		win_h = screenSize.size.height * 8 / 10 + GetTitleBarHeight();
	}

	const NSRect frameSize = NSMakeRect(win_x, win_y, win_w, win_h);
	[m_window setFrame:frameSize display:YES];
	[m_window enterFullscreenOnZoom];
}

void SystemBaseFrameBuffer::SetMode(const bool fullscreen, const bool hiDPI)
{
	if ([m_window.contentView isKindOfClass:[OpenGLCocoaView class]])
	{
		NSOpenGLView* const glView = [m_window contentView];
		[glView setWantsBestResolutionOpenGLSurface:hiDPI];
	}
	else
    {
		assert(m_window.screen != nil);
		assert([m_window.contentView layer] != nil);
#if HAVE_RT
		I_RT_LayoutRenderView(m_window, fullscreen);
#else
		[m_window.contentView layer].contentsScale = hiDPI ? m_window.screen.backingScaleFactor : 1.0;
#endif
	}

	if (vid_nativefullscreen && fullscreen != m_fullscreen)
	{
		[m_window toggleFullScreen:(nil)];
	}
	else if (fullscreen)
	{
		SetFullscreenMode();
	}
	else
	{
		SetWindowedMode();
	}

	[m_window updateTitle];

	if (![m_window isKeyWindow])
	{
		[m_window makeKeyAndOrderFront:nil];
	}

	m_fullscreen = fullscreen;
	m_hiDPI      = hiDPI;
}


void SystemBaseFrameBuffer::UseHiDPI(const bool hiDPI)
{
	if (frameBuffer != nullptr)
	{
		frameBuffer->SetMode(frameBuffer->m_fullscreen, hiDPI);
	}
}

void SystemBaseFrameBuffer::SetCursor(NSCursor* cursor)
{
	if (frameBuffer != nullptr)
	{
		NSWindow* const window = frameBuffer->m_window;
#if HAVE_RT
		id view = I_RT_RenderView(window);
#else
		id view = [window contentView];
#endif

		[view setCursor:cursor];
		[window invalidateCursorRectsForView:view];
	}
}

void SystemBaseFrameBuffer::SetWindowVisible(bool visible)
{
	if (frameBuffer != nullptr)
	{
		if (visible)
		{
			[frameBuffer->m_window orderFront:nil];
		}
		else
		{
			[frameBuffer->m_window orderOut:nil];
		}

		I_SetNativeMouse(!visible);
	}
}

void SystemBaseFrameBuffer::SetWindowTitle(const char* title)
{
	if (frameBuffer != nullptr)
	{
		NSString* const nsTitle = nullptr == title ? nil :
			[NSString stringWithCString:title encoding:NSISOLatin1StringEncoding];
		[frameBuffer->m_window setTitle:nsTitle];
	}
}


// ---------------------------------------------------------------------------


SystemGLFrameBuffer::SystemGLFrameBuffer(void *hMonitor, bool fullscreen)
: SystemBaseFrameBuffer(hMonitor, fullscreen)
{
}


void SystemGLFrameBuffer::SetVSync(bool vsync)
{
	const GLint value = vsync ? 1 : 0;

	[[NSOpenGLContext currentContext] setValues:&value
								   forParameter:NSOpenGLCPSwapInterval];
}


void SystemGLFrameBuffer::SetMode(const bool fullscreen, const bool hiDPI)
{
	NSOpenGLView* const glView = [m_window contentView];
	[glView setWantsBestResolutionOpenGLSurface:hiDPI];

	if (vid_nativefullscreen && fullscreen != m_fullscreen)
	{
		[m_window toggleFullScreen:(nil)];
	}
	else if (fullscreen)
	{
		SetFullscreenMode();
	}
	else
	{
		SetWindowedMode();
	}

	[m_window updateTitle];

	if (![m_window isKeyWindow])
	{
		[m_window makeKeyAndOrderFront:nil];
	}

	m_fullscreen = fullscreen;
	m_hiDPI      = hiDPI;
}


void SystemGLFrameBuffer::SwapBuffers()
{
	[[NSOpenGLContext currentContext] flushBuffer];
}


// ---------------------------------------------------------------------------


IVideo* Video;


// ---------------------------------------------------------------------------


void I_ShutdownGraphics()
{
	if (NULL != screen)
	{
		delete screen;
		screen = NULL;
	}

	delete Video;
	Video = NULL;
}

void I_InitGraphics()
{
	Video = new CocoaVideo;
}


#if HAVE_RT

// rt_platform.h

void I_RT_MessageBox(const char* title, const char* msg)
{
	NSAlert* alert = [[NSAlert alloc] init];
	alert.alertStyle = NSAlertStyleWarning;
	alert.messageText = [NSString stringWithUTF8String:title];
	alert.informativeText = [NSString stringWithUTF8String:msg];
	[alert addButtonWithTitle:@"OK"];
	[alert runModal];
	[alert release];
}

bool I_RT_AskYesNo(const char* title, const char* msg)
{
	NSAlert* alert = [[NSAlert alloc] init];
	alert.alertStyle = NSAlertStyleWarning;
	alert.messageText = [NSString stringWithUTF8String:title];
	alert.informativeText = [NSString stringWithUTF8String:msg];
	[alert addButtonWithTitle:@"Yes"];
	[alert addButtonWithTitle:@"No"];
	const NSModalResponse r = [alert runModal];
	[alert release];
	return r == NSAlertFirstButtonReturn;
}

int I_RT_AskAbortRetryIgnore(const char* title, const char* msg)
{
	NSAlert* alert = [[NSAlert alloc] init];
	alert.alertStyle = NSAlertStyleCritical;
	alert.messageText = [NSString stringWithUTF8String:title];
	alert.informativeText = [NSString stringWithUTF8String:msg];
	[alert addButtonWithTitle:@"Retry"];
	[alert addButtonWithTitle:@"Ignore"];
	[alert addButtonWithTitle:@"Abort"];
	const NSModalResponse r = [alert runModal];
	[alert release];
	return r == NSAlertFirstButtonReturn ? 1 : r == NSAlertSecondButtonReturn ? 2 : 0;
}

void I_RT_OpenUrl(const char* url)
{
	NSURL* u = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
	if (u != nil)
	{
		[[NSWorkspace sharedWorkspace] openURL:u];
	}
}

bool I_RT_IsWindowMinimized()
{
	NSWindow* const window = CocoaVideo::GetWindow();
	return window != nil && [window isMiniaturized];
}

void I_RT_GetScreenSize(int* width, int* height)
{
	NSScreen* const screen = [NSScreen mainScreen];
	const CGFloat scale = I_UseBackingPixels() ? screen.backingScaleFactor : 1.0;
	*width = int(screen.frame.size.width * scale);
	*height = int(screen.frame.size.height * scale);
}

// The display's modes in pixels, as macOS offers them in Displays settings (with the scaled ones)
void I_RT_GetDisplayModes(std::vector<std::pair<int, int>>& modes)
{
	const CGDirectDisplayID display = CGMainDisplayID();

	NSDictionary* options = @{ (__bridge NSString*)kCGDisplayShowDuplicateLowResolutionModes : @YES };
	CFArrayRef all = CGDisplayCopyAllDisplayModes(display, (__bridge CFDictionaryRef)options);
	if (all == nullptr)
	{
		return;
	}
	for (CFIndex i = 0; i < CFArrayGetCount(all); i++)
	{
		auto mode = static_cast<CGDisplayModeRef>(const_cast<void*>(CFArrayGetValueAtIndex(all, i)));
		if (!CGDisplayModeIsUsableForDesktopGUI(mode))
		{
			continue;
		}
		// pixel sizes, and the sizes in points: the scaled ones (lower) are rendered 1:1 too
		const std::pair<int, int> sizes[] = {
			{ int(CGDisplayModeGetPixelWidth(mode)), int(CGDisplayModeGetPixelHeight(mode)) },
			{ int(CGDisplayModeGetWidth(mode)), int(CGDisplayModeGetHeight(mode)) },
		};
		for (const auto& wh : sizes)
		{
			if (std::find(modes.begin(), modes.end(), wh) == modes.end())
			{
				modes.push_back(wh);
			}
		}
	}
	CFRelease(all);
}

const char* I_RT_GetProgramFolder()
{
	return progdir.GetChars();
}

#endif // HAVE_RT


// ---------------------------------------------------------------------------

CUSTOM_CVAR(Bool, vid_hidpi, true, CVAR_ARCHIVE | CVAR_GLOBALCONFIG | CVAR_NOINITCALL)
{
	SystemBaseFrameBuffer::UseHiDPI(self);
}

#if HAVE_RT
// The Metal Performance HUD (the same as MTL_HUD_ENABLED=1, which works only if the game
// is launched from a terminal: the app launched from Finder doesn't get environment variables).
// By the property's name: gzdoom doesn't link QuartzCore
static void I_RT_SetMetalHUD(CALayer* layer, bool enable)
{
	if (layer && [layer respondsToSelector:NSSelectorFromString(@"setDeveloperHUDProperties:")])
	{
		[layer setValue:(enable ? @{ @"mode" : @"default", @"logging" : @"default" } : nil)
				 forKey:@"developerHUDProperties"];
	}
}

void I_RT_ApplyMetalHUDOnCreate(CALayer* layer)
{
	I_RT_SetMetalHUD(layer, vid_metalhud);
}

// The resolution in fullscreen, scaled to the screen; 0 for the native resolution
CUSTOM_CVAR(Int, vid_rt_fullscreenwidth, 0, CVAR_ARCHIVE | CVAR_GLOBALCONFIG | CVAR_NOINITCALL)
{
	if (CocoaWindow* window = CocoaVideo::GetWindow())
	{
		I_RT_LayoutRenderView(window, vid_fullscreen);
	}
}

// With vid_rt_fullscreenwidth, its aspect ratio; 0 for the screen's
CUSTOM_CVAR(Int, vid_rt_fullscreenheight, 0, CVAR_ARCHIVE | CVAR_GLOBALCONFIG | CVAR_NOINITCALL)
{
	if (CocoaWindow* window = CocoaVideo::GetWindow())
	{
		I_RT_LayoutRenderView(window, vid_fullscreen);
	}
}

CUSTOM_CVAR(Bool, vid_metalhud, false, CVAR_ARCHIVE | CVAR_GLOBALCONFIG | CVAR_NOINITCALL)
{
	if (CocoaWindow* window = CocoaVideo::GetWindow())
	{
		I_RT_SetMetalHUD(I_RT_RenderView(window).layer, self);
	}
}
#endif


// ---------------------------------------------------------------------------


bool I_SetCursor(FGameTexture *cursorpic)
{
	NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
	NSCursor* cursor = nil;

	if (NULL != cursorpic && cursorpic->isValid())
	{
		// Create bitmap image representation

		auto sbuffer = cursorpic->GetTexture()->CreateTexBuffer(0);

		const NSInteger imageWidth  = sbuffer.mWidth;
		const NSInteger imageHeight = sbuffer.mHeight;
		const NSInteger imagePitch  = sbuffer.mWidth * 4;

		NSBitmapImageRep* bitmapImageRep = [NSBitmapImageRep alloc];
		[bitmapImageRep initWithBitmapDataPlanes:NULL
									  pixelsWide:imageWidth
									  pixelsHigh:imageHeight
								   bitsPerSample:8
								 samplesPerPixel:4
										hasAlpha:YES
										isPlanar:NO
								  colorSpaceName:NSDeviceRGBColorSpace
									 bytesPerRow:imagePitch
									bitsPerPixel:0];

		// Load bitmap data to representation

		uint8_t* buffer = [bitmapImageRep bitmapData];
		memcpy(buffer, sbuffer.mBuffer, imagePitch * imageHeight);

		// Swap red and blue components in each pixel

		for (size_t i = 0; i < size_t(imageWidth * imageHeight); ++i)
		{
			const size_t offset = i * 4;
			std::swap(buffer[offset    ], buffer[offset + 2]);
		}

		// Create image from representation and set it as cursor

		NSData* imageData = [bitmapImageRep representationUsingType:NSPNGFileType
														 properties:[NSDictionary dictionary]];
		NSImage* cursorImage = [[NSImage alloc] initWithData:imageData];

		cursor = [[NSCursor alloc] initWithImage:cursorImage
										 hotSpot:NSMakePoint(0.0f, 0.0f)];
	}

	SystemBaseFrameBuffer::SetCursor(cursor);

	[pool release];

	return true;
}


NSSize I_GetContentViewSize(const NSWindow* const window)
{
#if HAVE_RT
	const NSView* const view = I_RT_RenderView(window);
#else
	const NSView* const view = [window contentView];
#endif
	const NSSize frameSize   = [view frame].size;

#if HAVE_RT
	// the drawable's size
	if (view.layer != nil)
	{
		const CGFloat scale = view.layer.contentsScale;
		return NSMakeSize(frameSize.width * scale, frameSize.height * scale);
	}
#endif
	return I_UseBackingPixels()
		? [view convertSizeToBacking:frameSize]
		: frameSize;
}

void I_SetMainWindowVisible(bool visible)
{
	SystemBaseFrameBuffer::SetWindowVisible(visible);
}

// each platform has its own specific version of this function.
void I_SetWindowTitle(const char* title)
{
	SystemBaseFrameBuffer::SetWindowTitle(title);
}


#ifdef HAVE_VULKAN
void I_GetVulkanDrawableSize(int *width, int *height)
{
	NSWindow* const window = CocoaVideo::GetWindow();
	assert(window != nil);

	const NSSize size = I_GetContentViewSize(window);

	if (width != nullptr)
	{
		*width = int(size.width);
	}

	if (height != nullptr)
	{
		*height = int(size.height);
	}
}

bool I_CreateVulkanSurface(VkInstance instance, VkSurfaceKHR *surface)
{
	NSView *const view = CocoaVideo::GetWindow().contentView;
	CALayer *const layer = view.layer;

	// Set magnification filter for swapchain image when it's copied to a physical display surface
	// This is needed for gfx-portability because MoltenVK uses preferred nearest sampling by default
	const char *const magFilterEnv = getenv("MVK_CONFIG_SWAPCHAIN_MAG_FILTER_USE_NEAREST");
	const bool useNearestFilter = magFilterEnv == nullptr || strtol(magFilterEnv, nullptr, 0) != 0;
	layer.magnificationFilter = useNearestFilter ? kCAFilterNearest : kCAFilterLinear;

	if (vkCreateMetalSurfaceEXT)
	{
		// Preferred surface creation path
		VkMetalSurfaceCreateInfoEXT surfaceCreateInfo;
		surfaceCreateInfo.sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT;
		surfaceCreateInfo.pNext = nullptr;
		surfaceCreateInfo.flags = 0;
		surfaceCreateInfo.pLayer = static_cast<CAMetalLayer*>(layer);

		const VkResult result = vkCreateMetalSurfaceEXT(instance, &surfaceCreateInfo, nullptr, surface);
		return result == VK_SUCCESS;
	}

	// Deprecated surface creation path
	VkMacOSSurfaceCreateInfoMVK windowCreateInfo;
	windowCreateInfo.sType = VK_STRUCTURE_TYPE_MACOS_SURFACE_CREATE_INFO_MVK;
	windowCreateInfo.pNext = nullptr;
	windowCreateInfo.flags = 0;
	windowCreateInfo.pView = view;

	const VkResult result = vkCreateMacOSSurfaceMVK(instance, &windowCreateInfo, nullptr, surface);
	return result == VK_SUCCESS;
}
#endif


namespace
{
	TArray<uint8_t> polyPixelBuffer;
	GLuint polyTexture;

	int polyWidth = -1;
	int polyHeight = -1;
	int polyVSync = -1;
}

void I_PolyPresentInit()
{
	ogl_LoadFunctions();

	glGenTextures(1, &polyTexture);
	assert(polyTexture != 0);

	glEnable(GL_TEXTURE_RECTANGLE_ARB);
	glBindTexture(GL_TEXTURE_RECTANGLE_ARB, polyTexture);

	glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_MAG_FILTER, GL_NEAREST);

	glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

uint8_t *I_PolyPresentLock(int w, int h, bool vsync, int &pitch)
{
	static const int PIXEL_BYTES = 4;

	if (polyPixelBuffer.Size() == 0 || w != polyWidth || h != polyHeight)
	{
		polyPixelBuffer.Resize(w * h * PIXEL_BYTES);

		polyWidth = w;
		polyHeight = h;

		glMatrixMode(GL_MODELVIEW);
		glLoadIdentity();
		glMatrixMode(GL_PROJECTION);
		glLoadIdentity();
		glOrtho(0.0, w, h, 0.0, -1.0, 1.0);

		glViewport(0, 0, w, h);
	}

	if (vsync != polyVSync)
	{
		const GLint value = vsync ? 1 : 0;

		[[NSOpenGLContext currentContext] setValues:&value
									   forParameter:NSOpenGLCPSwapInterval];
	}

	pitch = w * PIXEL_BYTES;

	return &polyPixelBuffer[0];
}

void I_PolyPresentUnlock(int x, int y, int w, int h)
{
	glTexImage2D(GL_TEXTURE_RECTANGLE_ARB, 0, GL_RGBA8, w, h, 0, GL_BGRA, GL_UNSIGNED_BYTE, &polyPixelBuffer[0]);

	glBegin(GL_QUADS);
	glColor4f(1.0f, 1.0f, 1.0f, 1.0f);
	glTexCoord2f(0.0f, 0.0f);
	glVertex2f(0.0f, 0.0f);
	glTexCoord2f(w, 0.0f);
	glVertex2f(w, 0.0f);
	glTexCoord2f(w, h);
	glVertex2f(w, h);
	glTexCoord2f(0.0f, h);
	glVertex2f(0.0f, h);
	glEnd();

	glFlush();

	[[NSOpenGLContext currentContext] flushBuffer];
}

void I_PolyPresentDeinit()
{
	glBindTexture(GL_TEXTURE_2D, 0);
	glDeleteTextures(1, &polyTexture);
}
