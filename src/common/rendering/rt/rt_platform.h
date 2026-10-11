#pragma once

// Platform-specific parts of the RT renderer outside Windows.
// Windows uses Win32 API directly in rt_main.cpp / rt_cutscene.cpp.

#ifndef _WIN32

class DFrameBuffer;

// rt_main.cpp: creates the RTGL1 instance on a CAMetalLayer and the RT frame buffer
DFrameBuffer* RT_CreateMetalFrameBuffer( void* caMetalLayer, bool fullscreen );
void          RT_DestroyInstance();

// common/platform/posix/cocoa/i_video.mm
void I_RT_MessageBox( const char* title, const char* msg );
bool I_RT_AskYesNo( const char* title, const char* msg );
// returns 0 - abort, 1 - retry, 2 - ignore
int  I_RT_AskAbortRetryIgnore( const char* title, const char* msg );
void I_RT_OpenUrl( const char* url );
bool I_RT_IsWindowMinimized();
// main display, in pixels
#ifdef __APPLE__
#include <utility>
#include <vector>
// The display's modes in pixels
void I_RT_GetDisplayModes( std::vector< std::pair< int, int > >& modes );
#endif

void I_RT_GetScreenSize( int* width, int* height );
// folder of the executable, with a trailing slash
const char* I_RT_GetProgramFolder();

#endif
