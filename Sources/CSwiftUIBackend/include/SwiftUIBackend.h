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
typedef void (*SUIIndexCallback)(void *context, long index);

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

/// Asks for `render` to run on a later main run loop turn, at most four times
/// a second. Calls coalesce.
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

/// A vertically scrolling list of rows divided by separators. `key`
/// identifies the list across render passes so it keeps its scroll position.
SUIViewRef sui_list_create(unsigned long key);

/// Appends a row showing `content`. If `action` is non-null the row
/// highlights when touched and calls it; `disclosure` adds a chevron.
void sui_list_add_row(SUIViewRef list, SUIViewRef content, long disclosure, SUICallback action, void *context);

/// A list in the grouped style of a settings screen (`Form`): sections of
/// rows on a gray background. Rows are added with `sui_list_add_row`.
SUIViewRef sui_form_create(unsigned long key);

/// The top of a form section, with a header if `title_utf8` isn't null.
/// Add it with `sui_list_add_view` before the section's rows.
SUIViewRef sui_form_header_create(const char *title_utf8);

/// Appends `view` to a list as is, not as a row.
void sui_list_add_view(SUIViewRef list, SUIViewRef view);

/// A switch. `changed` is called with 1 or 0 when the user flips it.
SUIViewRef sui_switch_create(long is_on, SUIIndexCallback changed, void *context);

/// A stepper. Values are in hundredths; `changed` is called with the new one.
SUIViewRef sui_stepper_create(long value, long minimum, long maximum, long step,
                              SUIIndexCallback changed, void *context);

/// A slider that takes the width it is offered. Values are in hundredths and
/// `step` (0 for none) rounds them; `changed` is called while dragging, and
/// `ended`, which may be null, when the user lets go.
SUIViewRef sui_slider_create(long value, long minimum, long maximum, long step,
                             SUIIndexCallback changed, SUICallback ended, void *context);

/// A segmented control with `count` titles. `changed` is called with the
/// index the user picks.
SUIViewRef sui_segmented_create(const char *const *titles_utf8, long count, long selected,
                                SUIIndexCallback changed, void *context);

/// A spinning activity indicator.
SUIViewRef sui_activity_indicator_create(void);

/// Enables or disables a control, such as a button, switch or tappable view.
void sui_control_set_enabled(SUIViewRef control, long enabled);

/// A navigation controller's view. `key` identifies the controller across
/// render passes, so its stack and back button survive re-rendering.
SUIViewRef sui_navigation_create(unsigned long key);

/// Sets what the level at `index` (0 is the root) shows in this pass.
/// `title_utf8` and `trailing_item` may be null.
void sui_navigation_set_level(SUIViewRef navigation, long index, SUIViewRef content,
                              long fill_width, long fill_height,
                              const char *title_utf8, SUIViewRef trailing_item);

/// Shows the first `count` levels, pushing or popping as needed. When the
/// user goes back, `did_pop` is called with the number of levels left.
void sui_navigation_commit(SUIViewRef navigation, long count, SUIIndexCallback did_pop, void *context);

/// Calls `callback` on the main queue, on a later turn of the run loop.
void sui_dispatch_main(SUICallback callback, void *context);

/// Calls `callback` on the main queue after `milliseconds`.
void sui_dispatch_main_after(unsigned long milliseconds, SUICallback callback, void *context);

#endif
