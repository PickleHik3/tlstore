#include <pixman.h>
#include <wayland-client.h>
#include <stdio.h>

int main(void)
{
    pixman_color_t c = { 0xffff, 0, 0, 0xffff };
    pixman_image_t *img = pixman_image_create_solid_fill(&c);
    struct wl_display *d = wl_display_connect(NULL);
    printf("%p %p\n", (void *)img, (void *)d);
    return 0;
}
