#pragma once

#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 현재 스레드의 NSOpenGLContext를 사용하는 libmpv 렌더 컨텍스트를 만든다.
int tilo_mpv_render_context_create(mpv_render_context **result, mpv_handle *handle);

/// 지정한 OpenGL framebuffer에 현재 libmpv 프레임을 그린다.
int tilo_mpv_render_frame(
    mpv_render_context *context,
    int framebuffer,
    int width,
    int height,
    int flip_y
);

/// 영상 프레임이 아직 없을 때 화면을 검게 지운다.
void tilo_mpv_clear_frame(void);

#ifdef __cplusplus
}
#endif
