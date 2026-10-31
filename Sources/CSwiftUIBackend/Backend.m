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
/// Lists created in the current pass, and the last scroll offset of each list key.
static NSMutableArray *SUIPassLists;
static NSMapTable *SUILiveLists;
static NSMutableDictionary *SUIListOffsets;
/// Navigation controllers by key; they outlive render passes.
static NSMutableDictionary *SUINavigationControllers;
/// Associates a navigation controller with its state and its view.
static const void *SUINavigationStateKey = &SUINavigationStateKey;

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

void sui_dispatch_main(SUICallback callback, void *context) {
    dispatch_async_f(dispatch_get_main_queue(), context, callback);
}

void sui_dispatch_main_after(unsigned long milliseconds, SUICallback callback, void *context) {
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)milliseconds * NSEC_PER_MSEC),
                     dispatch_get_main_queue(), context, callback);
}

#pragma mark - Render pass

void sui_render_begin(void) {
    SUIPendingViews = [NSMutableArray array];
    SUIPassLists = [NSMutableArray array];
    if (!SUIListOffsets) {
        SUIListOffsets = [NSMutableDictionary dictionary];
        SUILiveLists = [NSMapTable strongToWeakObjectsMapTable];
    }
    // The lists on screen are about to be replaced; remember where they were.
    for (NSNumber *key in SUILiveLists) {
        UIScrollView *list = [SUILiveLists objectForKey:key];
        if (list.window) SUIListOffsets[key] = [NSValue valueWithCGPoint:list.contentOffset];
    }
}

/// Replaces `controller`'s content with `root`, filling or centered in each dimension
/// between the layout guides.
static void SUIInstall(UIViewController *controller, UIView *root, long fillWidth, long fillHeight) {
    UIView *container = controller.view;
    for (UIView *subview in [container.subviews copy]) {
        [subview removeFromSuperview];
    }

    [container addSubview:root];
    // A navigation controller lays out its bar under the status bar itself.
    if (objc_getAssociatedObject(root, SUINavigationStateKey)) {
        SUIPin(root, container, 0, 0, 0, 0);
        return;
    }
    id<UILayoutSupport> top = controller.topLayoutGuide;
    id<UILayoutSupport> bottom = controller.bottomLayoutGuide;
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
}

/// Scrolls each list made in this pass back to where its predecessor was.
static void SUIRestoreListOffsets(void) {
    for (UIScrollView *list in SUIPassLists) {
        NSValue *saved = SUIListOffsets[objc_getAssociatedObject(list, &SUIListOffsets)];
        if (!saved) continue;
        UIView *top = list;
        while (top.superview) top = top.superview;
        [top layoutIfNeeded];
        CGFloat maxY = MAX(0, list.contentSize.height - list.bounds.size.height);
        list.contentOffset = CGPointMake(0, MIN(saved.CGPointValue.y, maxY));
    }
    SUIPassLists = nil;
}

void sui_render_commit(SUIViewRef rootRef, long fillWidth, long fillHeight) {
    SUIInstall(SUIRootController, SUIView(rootRef), fillWidth, fillHeight);
    SUIRestoreListOffsets();
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

#pragma mark - List

/// A right-pointing chevron, like UITableViewCell's disclosure indicator.
@interface SUIChevronView : UIView
@end

@implementation SUIChevronView
- (instancetype)init {
    if ((self = [super init])) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(1.5, 1.5)];
    [path addLineToPoint:CGPointMake(self.bounds.size.width - 1.5, self.bounds.size.height / 2)];
    [path addLineToPoint:CGPointMake(1.5, self.bounds.size.height - 1.5)];
    path.lineWidth = 2;
    path.lineCapStyle = kCGLineCapRound;
    path.lineJoinStyle = kCGLineJoinRound;
    [[UIColor colorWithRed:0.78 green:0.78 blue:0.8 alpha:1] setStroke];
    [path stroke];
}
@end

/// A list row that turns gray while touched, like a selected table cell.
@interface SUIListRow : UIControl
@end

@implementation SUIListRow
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = highlighted ? [UIColor colorWithWhite:0.85 alpha:1] : [UIColor whiteColor];
}
@end

SUIViewRef sui_list_create(unsigned long key) {
    UIScrollView *list = [[UIScrollView alloc] init];
    list.alwaysBounceVertical = YES;
    list.backgroundColor = [UIColor whiteColor];
    SUIMakeFlexible(list);

    UIStackView *rows = [[UIStackView alloc] init];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    [list addSubview:rows];
    [NSLayoutConstraint activateConstraints:@[
        [rows.topAnchor constraintEqualToAnchor:list.topAnchor],
        [rows.leadingAnchor constraintEqualToAnchor:list.leadingAnchor],
        [rows.trailingAnchor constraintEqualToAnchor:list.trailingAnchor],
        [rows.bottomAnchor constraintEqualToAnchor:list.bottomAnchor],
        [rows.widthAnchor constraintEqualToAnchor:list.widthAnchor],
    ]];

    NSNumber *listKey = @(key);
    objc_setAssociatedObject(list, &SUIListOffsets, listKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [SUILiveLists setObject:list forKey:listKey];
    [SUIPassLists addObject:list];
    return SUIKeep(list);
}

void sui_list_add_row(SUIViewRef listRef, SUIViewRef contentRef, long disclosure, SUICallback action, void *context) {
    UIStackView *rows = (UIStackView *)SUIView(listRef).subviews.firstObject;
    UIView *content = SUIView(contentRef);

    UIControl *row = action ? [[SUIListRow alloc] init] : [[UIControl alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.backgroundColor = [UIColor whiteColor];
    content.userInteractionEnabled = action == NULL;
    [row addSubview:content];

    CGFloat trailing = 16;
    if (disclosure) {
        SUIChevronView *chevron = [[SUIChevronView alloc] init];
        chevron.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:chevron];
        [NSLayoutConstraint activateConstraints:@[
            [chevron.widthAnchor constraintEqualToConstant:8],
            [chevron.heightAnchor constraintEqualToConstant:13],
            [chevron.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [row.trailingAnchor constraintEqualToAnchor:chevron.trailingAnchor constant:16],
        ]];
        trailing += 8 + 12;
    }

    // Rows are at least as tall as a table cell; content hugs the leading edge.
    NSLayoutConstraint *minHeight = [row.heightAnchor constraintGreaterThanOrEqualToConstant:44];
    NSLayoutConstraint *contentTrailing = [row.trailingAnchor constraintGreaterThanOrEqualToAnchor:content.trailingAnchor constant:trailing];
    [NSLayoutConstraint activateConstraints:@[
        minHeight,
        contentTrailing,
        [content.topAnchor constraintGreaterThanOrEqualToAnchor:row.topAnchor constant:11],
        [row.bottomAnchor constraintGreaterThanOrEqualToAnchor:content.bottomAnchor constant:11],
        [content.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [content.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
    ]];

    UIView *separator = [[UIView alloc] init];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor colorWithRed:0.78 green:0.78 blue:0.8 alpha:1];
    [row addSubview:separator];
    [NSLayoutConstraint activateConstraints:@[
        [separator.heightAnchor constraintEqualToConstant:1.0 / [UIScreen mainScreen].scale],
        [separator.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [separator.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [separator.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
    ]];

    if (action) SUIAttachAction(row, action, context);
    [rows addArrangedSubview:row];
    [SUIPendingViews addObject:row];
}

#pragma mark - Navigation

/// One level of a navigation stack. Its content is replaced on every pass.
@interface SUILevelController : UIViewController
@end

@implementation SUILevelController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.automaticallyAdjustsScrollViewInsets = NO;
}
@end

/// Tells Swift when the user pops levels with the back button or swipe.
@interface SUINavigationState : NSObject <UINavigationControllerDelegate>
@property (nonatomic, strong) NSMutableArray<SUILevelController *> *levels;
@property (nonatomic) NSInteger count;
@property (nonatomic) SUIIndexCallback didPop;
@property (nonatomic) void *context;
@end

@implementation SUINavigationState
- (void)navigationController:(UINavigationController *)navigationController
       didShowViewController:(UIViewController *)viewController
                    animated:(BOOL)animated {
    NSInteger count = navigationController.viewControllers.count;
    if (count < self.count) {
        self.count = count;
        if (self.didPop) self.didPop(self.context, count);
    }
}
@end

static UINavigationController *SUINavigationController(SUIViewRef ref) {
    return objc_getAssociatedObject(SUIView(ref), SUINavigationStateKey);
}

static SUINavigationState *SUINavigationStateOf(UINavigationController *navigation) {
    return (SUINavigationState *)navigation.delegate;
}

SUIViewRef sui_navigation_create(unsigned long key) {
    if (!SUINavigationControllers) SUINavigationControllers = [NSMutableDictionary dictionary];
    UINavigationController *navigation = SUINavigationControllers[@(key)];
    if (!navigation) {
        SUILevelController *root = [[SUILevelController alloc] init];
        navigation = [[UINavigationController alloc] initWithRootViewController:root];
        SUINavigationState *state = [[SUINavigationState alloc] init];
        state.levels = [NSMutableArray arrayWithObject:root];
        state.count = 1;
        // The delegate is weak; the controller keeps its state alive.
        objc_setAssociatedObject(navigation, SUINavigationStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        navigation.delegate = state;
        objc_setAssociatedObject(navigation.view, SUINavigationStateKey, navigation, OBJC_ASSOCIATION_ASSIGN);
        [SUIRootController addChildViewController:navigation];
        [navigation didMoveToParentViewController:SUIRootController];
        SUINavigationControllers[@(key)] = navigation;
    }
    SUIMakeFlexible(navigation.view);
    return SUIKeep(navigation.view);
}

void sui_navigation_set_level(SUIViewRef navigationRef, long index, SUIViewRef contentRef,
                              long fillWidth, long fillHeight,
                              const char *titleUTF8, SUIViewRef trailingRef) {
    UINavigationController *navigation = SUINavigationController(navigationRef);
    SUINavigationState *state = SUINavigationStateOf(navigation);
    while (state.levels.count <= (NSUInteger)index) {
        [state.levels addObject:[[SUILevelController alloc] init]];
    }
    SUILevelController *level = state.levels[index];
    SUIInstall(level, SUIView(contentRef), fillWidth, fillHeight);
    level.navigationItem.title = titleUTF8 ? [NSString stringWithUTF8String:titleUTF8] : nil;

    if (trailingRef) {
        UIView *item = SUIView(trailingRef);
        CGSize size = [item systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
        item.translatesAutoresizingMaskIntoConstraints = YES;
        item.frame = CGRectMake(0, 0, size.width, size.height);
        level.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:item];
    } else {
        level.navigationItem.rightBarButtonItem = nil;
    }
}

void sui_navigation_commit(SUIViewRef navigationRef, long count, SUIIndexCallback didPop, void *context) {
    UINavigationController *navigation = SUINavigationController(navigationRef);
    SUINavigationState *state = SUINavigationStateOf(navigation);
    state.didPop = didPop;
    state.context = context;
    state.count = count;
    if ((NSUInteger)count < state.levels.count) {
        [state.levels removeObjectsInRange:NSMakeRange(count, state.levels.count - count)];
    }

    NSArray *current = navigation.viewControllers;
    NSArray *desired = [state.levels copy];
    if ([current isEqualToArray:desired]) return;

    BOOL isPush = desired.count == current.count + 1
        && [[desired subarrayWithRange:NSMakeRange(0, current.count)] isEqualToArray:current];
    BOOL isPop = desired.count < current.count
        && [[current subarrayWithRange:NSMakeRange(0, desired.count)] isEqualToArray:desired];
    if (isPush) {
        [navigation pushViewController:desired.lastObject animated:YES];
    } else if (isPop) {
        [navigation popToViewController:desired.lastObject animated:YES];
    } else {
        [navigation setViewControllers:desired animated:NO];
    }
}
