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
// through the system wouldn't ask, but on an iPhone (a 16 Pro, Nov 2026) the game view's paste: never
// came for Cmd+V, from the system's shortcut or a UIKeyCommand of its own, while it takes the key presses.
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

static NSString *sp_pb_read(void) {
    SP_CLIPBOARD_ONCE("the game read the clipboard");
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
