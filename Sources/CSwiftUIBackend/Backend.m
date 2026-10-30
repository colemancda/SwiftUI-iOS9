// UIKit implementation of SwiftUIBackend.h for iOS 9.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SwiftUIBackend.h"

// From <crt_externs.h>, which the iOS SDK doesn't ship; libsystem_c exports them.
extern int *_NSGetArgc(void);
extern char ***_NSGetArgv(void);

static SUICallback SUILaunch;
static SUICallback SUIRender;
static BOOL SUIRenderScheduled;
static NSMutableArray *SUIPendingViews;
static UIViewController *SUIRootController;

#pragma mark - Helpers

static UIColor *SUIColorFromRGBA(unsigned long rgba) {
    return [UIColor colorWithRed:((rgba >> 24) & 0xFF) / 255.0
                           green:((rgba >> 16) & 0xFF) / 255.0
                            blue:((rgba >> 8) & 0xFF) / 255.0
                           alpha:(rgba & 0xFF) / 255.0];
}

static UIFont *SUIFontMake(long size, long weight) {
    CGFloat uiWeight;
    switch (weight) {
        case SUIFontWeightMedium: uiWeight = UIFontWeightMedium; break;
        case SUIFontWeightSemibold: uiWeight = UIFontWeightSemibold; break;
        case SUIFontWeightBold: uiWeight = UIFontWeightBold; break;
        default: uiWeight = UIFontWeightRegular; break;
    }
    return [UIFont systemFontOfSize:size weight:uiWeight];
}

/// Keeps `view` alive until the render pass is committed.
static SUIViewRef SUIKeep(UIView *view) {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [SUIPendingViews addObject:view];
    return (__bridge SUIViewRef)view;
}

static UIView *SUIView(SUIViewRef ref) {
    return (__bridge UIView *)ref;
}

static void SUIPin(UIView *child, UIView *parent, long top, long leading, long bottom, long trailing) {
    [parent addSubview:child];
    [NSLayoutConstraint activateConstraints:@[
        [child.topAnchor constraintEqualToAnchor:parent.topAnchor constant:top],
        [child.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor constant:leading],
        [parent.bottomAnchor constraintEqualToAnchor:child.bottomAnchor constant:bottom],
        [parent.trailingAnchor constraintEqualToAnchor:child.trailingAnchor constant:trailing],
    ]];
}

#pragma mark - Actions

@interface SUIActionTarget : NSObject
@property (nonatomic) SUICallback action;
@property (nonatomic) void *context;
@end

@implementation SUIActionTarget
- (void)fire {
    if (self.action) self.action(self.context);
}
@end

static const void *SUIActionTargetKey = &SUIActionTargetKey;

static void SUIAttachAction(UIControl *control, SUICallback action, void *context) {
    SUIActionTarget *target = [[SUIActionTarget alloc] init];
    target.action = action;
    target.context = context;
    [control addTarget:target action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    // UIControl holds targets weakly; the control owns its target here.
    objc_setAssociatedObject(control, SUIActionTargetKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/// A control that dims its content while touched, like a SwiftUI plain button.
@interface SUITappable : UIControl
@end

@implementation SUITappable
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.4 : 1.0;
}
@end

#pragma mark - App

@interface SUIAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SUIAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    SUIRootController = [[UIViewController alloc] init];
    SUIRootController.view.backgroundColor = [UIColor whiteColor];
    self.window.rootViewController = SUIRootController;
    [self.window makeKeyAndVisible];
    if (SUILaunch) SUILaunch(NULL);
    if (SUIRender) SUIRender(NULL);
    return YES;
}
@end

void sui_run(SUICallback launch, SUICallback render) {
    SUILaunch = launch;
    SUIRender = render;
    @autoreleasepool {
        UIApplicationMain(*_NSGetArgc(), *_NSGetArgv(), nil, NSStringFromClass([SUIAppDelegate class]));
    }
}

void sui_schedule_render(void) {
    if (SUIRenderScheduled) return;
    SUIRenderScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        SUIRenderScheduled = NO;
        if (SUIRender) SUIRender(NULL);
    });
}

#pragma mark - Render pass

void sui_render_begin(void) {
    SUIPendingViews = [NSMutableArray array];
}

void sui_render_commit(SUIViewRef rootRef, long fillWidth, long fillHeight) {
    UIView *container = SUIRootController.view;
    for (UIView *subview in [container.subviews copy]) {
        [subview removeFromSuperview];
    }

    UIView *root = SUIView(rootRef);
    [container addSubview:root];
    id<UILayoutSupport> top = SUIRootController.topLayoutGuide;
    id<UILayoutSupport> bottom = SUIRootController.bottomLayoutGuide;
    NSMutableArray *constraints = [NSMutableArray array];

    if (fillWidth) {
        [constraints addObject:[root.leadingAnchor constraintEqualToAnchor:container.leadingAnchor]];
        [constraints addObject:[root.trailingAnchor constraintEqualToAnchor:container.trailingAnchor]];
    } else {
        [constraints addObject:[root.centerXAnchor constraintEqualToAnchor:container.centerXAnchor]];
        [constraints addObject:[root.leadingAnchor constraintGreaterThanOrEqualToAnchor:container.leadingAnchor]];
        [constraints addObject:[root.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor]];
    }

    if (fillHeight) {
        [constraints addObject:[root.topAnchor constraintEqualToAnchor:top.bottomAnchor]];
        [constraints addObject:[root.bottomAnchor constraintEqualToAnchor:bottom.topAnchor]];
    } else {
        [constraints addObject:[root.centerYAnchor constraintEqualToAnchor:container.centerYAnchor]];
        [constraints addObject:[root.topAnchor constraintGreaterThanOrEqualToAnchor:top.bottomAnchor]];
        [constraints addObject:[root.bottomAnchor constraintLessThanOrEqualToAnchor:bottom.topAnchor]];
    }

    [NSLayoutConstraint activateConstraints:constraints];
    SUIPendingViews = nil;
}

#pragma mark - Views

SUIViewRef sui_label_create(const char *utf8) {
    UILabel *label = [[UILabel alloc] init];
    label.text = [NSString stringWithUTF8String:utf8];
    label.numberOfLines = 0;
    label.font = SUIFontMake(17, SUIFontWeightRegular);
    return SUIKeep(label);
}

void sui_label_set_font(SUIViewRef label, long size, long weight) {
    ((UILabel *)SUIView(label)).font = SUIFontMake(size, weight);
}

void sui_label_set_color(SUIViewRef label, unsigned long rgba) {
    ((UILabel *)SUIView(label)).textColor = SUIColorFromRGBA(rgba);
}

SUIViewRef sui_button_create(const char *titleUTF8, SUICallback action, void *context) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:[NSString stringWithUTF8String:titleUTF8] forState:UIControlStateNormal];
    button.titleLabel.font = SUIFontMake(17, SUIFontWeightRegular);
    SUIAttachAction(button, action, context);
    return SUIKeep(button);
}

void sui_button_set_font(SUIViewRef button, long size, long weight) {
    ((UIButton *)SUIView(button)).titleLabel.font = SUIFontMake(size, weight);
}

void sui_button_set_color(SUIViewRef button, unsigned long rgba) {
    SUIView(button).tintColor = SUIColorFromRGBA(rgba);
}

SUIViewRef sui_tappable_create(SUIViewRef contentRef, SUICallback action, void *context) {
    SUITappable *control = [[SUITappable alloc] init];
    UIView *content = SUIView(contentRef);
    content.userInteractionEnabled = NO;
    SUIPin(content, control, 0, 0, 0, 0);
    SUIAttachAction(control, action, context);
    return SUIKeep(control);
}

SUIViewRef sui_stack_create(long axis, long spacing, long alignment) {
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = axis == SUIAxisVertical ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    stack.spacing = spacing;
    stack.distribution = UIStackViewDistributionFill;
    switch (alignment) {
        case SUIAlignmentLeading:
            stack.alignment = axis == SUIAxisVertical ? UIStackViewAlignmentLeading : UIStackViewAlignmentTop;
            break;
        case SUIAlignmentTrailing:
            stack.alignment = axis == SUIAxisVertical ? UIStackViewAlignmentTrailing : UIStackViewAlignmentBottom;
            break;
        default:
            stack.alignment = UIStackViewAlignmentCenter;
            break;
    }
    return SUIKeep(stack);
}

void sui_stack_add(SUIViewRef stackRef, SUIViewRef childRef, long stretchCrossAxis) {
    UIStackView *stack = (UIStackView *)SUIView(stackRef);
    UIView *child = SUIView(childRef);
    [stack addArrangedSubview:child];
    if (stretchCrossAxis) {
        NSLayoutConstraint *stretch = stack.axis == UILayoutConstraintAxisVertical
            ? [child.widthAnchor constraintEqualToAnchor:stack.widthAnchor]
            : [child.heightAnchor constraintEqualToAnchor:stack.heightAnchor];
        stretch.active = YES;
    }
}

/// Lets `view` grow and shrink freely in both directions.
static void SUIMakeFlexible(UIView *view) {
    for (NSNumber *axis in @[@(UILayoutConstraintAxisHorizontal), @(UILayoutConstraintAxisVertical)]) {
        [view setContentHuggingPriority:1 forAxis:axis.integerValue];
        [view setContentCompressionResistancePriority:1 forAxis:axis.integerValue];
    }
}

SUIViewRef sui_color_view_create(unsigned long rgba) {
    UIView *view = [[UIView alloc] init];
    view.backgroundColor = SUIColorFromRGBA(rgba);
    SUIMakeFlexible(view);
    return SUIKeep(view);
}

SUIViewRef sui_spacer_create(long minLength) {
    UIView *spacer = [[UIView alloc] init];
    SUIMakeFlexible(spacer);
    NSLayoutConstraint *width = [spacer.widthAnchor constraintGreaterThanOrEqualToConstant:minLength];
    NSLayoutConstraint *height = [spacer.heightAnchor constraintGreaterThanOrEqualToConstant:minLength];
    width.priority = 999;
    height.priority = 999;
    [NSLayoutConstraint activateConstraints:@[width, height]];
    return SUIKeep(spacer);
}

SUIViewRef sui_padding_create(SUIViewRef child, long top, long leading, long bottom, long trailing) {
    UIView *container = [[UIView alloc] init];
    SUIPin(SUIView(child), container, top, leading, bottom, trailing);
    return SUIKeep(container);
}

SUIViewRef sui_background_create(SUIViewRef child, unsigned long rgba) {
    UIView *container = [[UIView alloc] init];
    container.backgroundColor = SUIColorFromRGBA(rgba);
    SUIPin(SUIView(child), container, 0, 0, 0, 0);
    return SUIKeep(container);
}

void sui_view_set_size(SUIViewRef ref, long width, long height) {
    UIView *view = SUIView(ref);
    if (width >= 0) [view.widthAnchor constraintEqualToConstant:width].active = YES;
    if (height >= 0) [view.heightAnchor constraintEqualToConstant:height].active = YES;
}
