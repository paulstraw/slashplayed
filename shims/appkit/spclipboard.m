// The clipboard: NSPasteboard's general pasteboard over UIPasteboard, text only, which is all a game's
// edit box moves. The generated shim had NSPasteboard as a stub class that answers everything with nil,
// so the game's Cmd+V pasted nothing and its copies went nowhere. #included at the end of the generated
// libspAppKit.m (gen_stubs.py EXTRA_INCLUDES).
//
// The client's pasteboard types are real strings (gen_stubs.py DATA_OVERRIDES gives NSPasteboardTypeString
// and NSPasteboardTypeFileURL macOS's values), so a type is text only when it names text: a file-URL
// check answers no, as it should on a device with no files to paste, and a type a later patch brings in
// is refused rather than taken for text.
//
// Reading another app's text shows iOS's "Allow Paste" prompt (Settings > Slashplayed > Paste from Other
// Apps > Allow turns it off), and the read waits for the answer on the main thread, so the game stops
// drawing until it's given (its sound plays on). It asks once per copy: the same copy read again, and
// text this app put there (the game's own copy), never ask; nor do hasStrings, types, and changeCount,
// which the client polls about every frame once +generalPasteboard answers. A paste the person starts
// through the system doesn't ask: the touch edit menu's Paste (spevent.m) is one. A hardware Cmd+V isn't,
// here: on an iPhone (a 16 Pro, Nov 2026) the game view's paste: never came for it, from the system's
// shortcut or a UIKeyCommand of its own, while it takes the key presses.
//
// Nothing here logs the clipboard's text or its length: chat, the authenticator code, and a password can
// all go through it. Only that a read or write happened, once each.

static void sp_clipboard_say(const char *what) {
    os_log(OS_LOG_DEFAULT, "[sp:AppKit] clipboard: %{public}s", what);
    fprintf(stderr, "[sp:AppKit] clipboard: %s\n", what);
}

#define SP_CLIPBOARD_ONCE(what) do { \
    static atomic_flag once = ATOMIC_FLAG_INIT; \
    if (!atomic_flag_test_and_set(&once)) sp_clipboard_say(what); \
} while (0)

// The touch edit menu's Paste (spevent.m's paste:) is a paste the person started through the system, so
// its read doesn't prompt. The text is kept for the Cmd+V that paste: posts, which the game answers by
// reading here, and for any later read of the same copy (changeCount unchanged), which would otherwise
// prompt again; a new copy, the game's own included, changes the count and drops it.
static NSString *sp_pb_kept;
static NSInteger sp_pb_kept_count;

static void sp_clipboard_keep_paste(void) {
    UIPasteboard *pb = UIPasteboard.generalPasteboard;
    sp_pb_kept = pb.string;
    sp_pb_kept_count = pb.changeCount;
    SP_CLIPBOARD_ONCE("the edit menu's Paste read the clipboard");
}

// Which way each read goes is logged (reads come once per paste, not per frame): the edit menu's text, or
// the clipboard itself because nothing was kept or the copy changed since.
static NSString *sp_pb_read(void) {
    static int logged;
    BOOL kept = sp_pb_kept && UIPasteboard.generalPasteboard.changeCount == sp_pb_kept_count;
    if (logged++ < 20)
        sp_clipboard_say(kept ? "the game read the edit menu's paste"
                         : sp_pb_kept ? "the game read the clipboard (a new copy since the edit menu's paste)"
                                      : "the game read the clipboard");
    if (kept) return sp_pb_kept;
    sp_pb_kept = nil;
    return UIPasteboard.generalPasteboard.string;
}

static BOOL sp_pb_is_text(id type) {
    if (![type isKindOfClass:NSString.class]) return NO;
    return [type isEqual:sp_NSPasteboardTypeString] || [type isEqual:@"NSStringPboardType"] ||
           [type isEqual:@"public.plain-text"] || [type isEqual:@"public.text"];
}

@implementation NSPasteboard (SPClipboard)
+ (id)generalPasteboard {
    static id pb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pb = [[self alloc] init]; });
    return pb;
}
- (NSInteger)changeCount {
    return UIPasteboard.generalPasteboard.changeCount;
}
- (NSInteger)clearContents {
    UIPasteboard.generalPasteboard.items = @[];
    return UIPasteboard.generalPasteboard.changeCount;
}
// The older way to start a copy: setString:forType: follows, so nothing is cleared here.
- (NSInteger)declareTypes:(NSArray *)types owner:(id)owner {
    return UIPasteboard.generalPasteboard.changeCount;
}
- (NSArray *)types {
    return UIPasteboard.generalPasteboard.hasStrings ? @[ sp_NSPasteboardTypeString ] : @[];
}
- (NSString *)availableTypeFromArray:(NSArray *)types {
    if (!UIPasteboard.generalPasteboard.hasStrings) return nil;
    for (id type in types)
        if (sp_pb_is_text(type)) return type;
    return nil;
}
- (NSString *)stringForType:(NSString *)type {
    return sp_pb_is_text(type) ? sp_pb_read() : nil;
}
- (NSData *)dataForType:(NSString *)type {
    return sp_pb_is_text(type) ? [sp_pb_read() dataUsingEncoding:NSUTF8StringEncoding] : nil;
}
- (BOOL)setString:(NSString *)string forType:(NSString *)type {
    if (!sp_pb_is_text(type) || ![string isKindOfClass:NSString.class]) return NO;
    SP_CLIPBOARD_ONCE("the game wrote the clipboard (setString:forType:)");
    UIPasteboard.generalPasteboard.string = string;
    return YES;
}
- (BOOL)setData:(NSData *)data forType:(NSString *)type {
    NSString *s = sp_pb_is_text(type) && data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (!s) return NO;
    SP_CLIPBOARD_ONCE("the game wrote the clipboard (setData:forType:)");
    UIPasteboard.generalPasteboard.string = s;
    return YES;
}
@end
