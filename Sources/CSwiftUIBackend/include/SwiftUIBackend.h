// C interface between the Embedded Swift `SwiftUI` module and the UIKit backend.
//
// Only pointers, `long` and `unsigned long` cross this boundary. Embedded Swift
// is compiled for bare-metal armv7, whose calling convention differs from iOS's
// for floating-point and struct arguments, so sizes are whole points and
// colors are packed 0xRRGGBBAA.
//
// Views are created during a render pass and are owned by the backend until
// the pass is committed; Swift never retains or releases them.

#ifndef SWIFTUI_BACKEND_H
#define SWIFTUI_BACKEND_H

typedef void *SUIViewRef;
typedef void (*SUICallback)(void *context);

enum {
    SUIAxisHorizontal = 0,
    SUIAxisVertical = 1,
};

enum {
    SUIAlignmentCenter = 0,
    SUIAlignmentLeading = 1,
    SUIAlignmentTrailing = 2,
};

enum {
    SUIFontWeightRegular = 0,
    SUIFontWeightMedium = 1,
    SUIFontWeightSemibold = 2,
    SUIFontWeightBold = 3,
};

/// Starts UIKit. `launch` is called once the window exists; `render` is called
/// for the first frame and whenever an update was scheduled.
/// Does not return.
void sui_run(SUICallback launch, SUICallback render);

/// Asks for `render` to run on the next main run loop turn. Calls coalesce.
void sui_schedule_render(void);

/// Starts a render pass. Views created until `sui_render_commit` are kept
/// alive by the backend.
void sui_render_begin(void);

/// Replaces the window's content with `root`, then ends the pass.
/// `fill_width`/`fill_height` pin `root` to the screen edges in that
/// dimension instead of centering it.
void sui_render_commit(SUIViewRef root, long fill_width, long fill_height);

SUIViewRef sui_label_create(const char *utf8);
void sui_label_set_font(SUIViewRef label, long size, long weight);
void sui_label_set_color(SUIViewRef label, unsigned long rgba);

/// A system button with a text title.
SUIViewRef sui_button_create(const char *title_utf8, SUICallback action, void *context);
void sui_button_set_font(SUIViewRef button, long size, long weight);
void sui_button_set_color(SUIViewRef button, unsigned long rgba);

/// A control that shows `content` and calls `action` when tapped.
SUIViewRef sui_tappable_create(SUIViewRef content, SUICallback action, void *context);

SUIViewRef sui_stack_create(long axis, long spacing, long alignment);

/// Appends `child`. If `stretch_cross_axis` is nonzero, the child also fills
/// the stack across its axis (full width in a vertical stack).
void sui_stack_add(SUIViewRef stack, SUIViewRef child, long stretch_cross_axis);

/// A view filled with a color that takes whatever space it is offered.
SUIViewRef sui_color_view_create(unsigned long rgba);

/// A view that stretches along the axis of the stack it is in.
SUIViewRef sui_spacer_create(long min_length);

/// Wraps `child` with insets (in points).
SUIViewRef sui_padding_create(SUIViewRef child, long top, long leading, long bottom, long trailing);

/// Wraps `child` in a view with a background color.
SUIViewRef sui_background_create(SUIViewRef child, unsigned long rgba);

/// Constrains `view`'s width and/or height; pass -1 to leave one unconstrained.
void sui_view_set_size(SUIViewRef view, long width, long height);

#endif
