#include "MpvBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#define GL_SILENCE_DEPRECATION
#include <OpenGL/gl.h>

static void *tilo_get_proc_address(void *context, const char *name) {
    (void)context;
    CFStringRef symbol = CFStringCreateWithCString(
        kCFAllocatorDefault,
        name,
        kCFStringEncodingASCII
    );
    if (!symbol) {
        return NULL;
    }
    CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.opengl"));
    void *address = bundle ? CFBundleGetFunctionPointerForName(bundle, symbol) : NULL;
    CFRelease(symbol);
    return address;
}

int tilo_mpv_render_context_create(mpv_render_context **result, mpv_handle *handle) {
    mpv_opengl_init_params gl = {
        .get_proc_address = tilo_get_proc_address,
        .get_proc_address_ctx = NULL,
    };
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL },
        { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl },
        { MPV_RENDER_PARAM_INVALID, NULL },
    };
    return mpv_render_context_create(result, handle, params);
}

int tilo_mpv_render_frame(
    mpv_render_context *context,
    int framebuffer,
    int width,
    int height,
    int flip_y
) {
    mpv_opengl_fbo fbo = {
        .fbo = framebuffer,
        .w = width,
        .h = height,
        .internal_format = 0,
    };
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_OPENGL_FBO, &fbo },
        { MPV_RENDER_PARAM_FLIP_Y, &flip_y },
        { MPV_RENDER_PARAM_INVALID, NULL },
    };
    return mpv_render_context_render(context, params);
}

void tilo_mpv_clear_frame(void) {
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
}
