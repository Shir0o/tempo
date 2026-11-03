/// OAuth client IDs for Google Drive sign-in.
///
/// Client IDs are public identifiers, not secrets: they ship inside the app.
library;

/// Web application client ID.
///
/// Required on Android as `serverClientId` because the app does not use
/// `google-services.json`.
const String googleWebClientId =
    '703545478046-3icqb3r065d59ih7odsb49dofd51ulkr.apps.googleusercontent.com';

/// iOS-type client ID used by `GoogleSignIn` on macOS (bundle ID match).
const String googleMacosClientId =
    '703545478046-ubbsj0r20tnjv2qlq83bm1o1facagmr1.apps.googleusercontent.com';

/// Reversed client ID registered as a URL scheme in `macos/Runner/Info.plist`.
const String googleMacosReversedClientId =
    'com.googleusercontent.apps.703545478046-ubbsj0r20tnjv2qlq83bm1o1facagmr1';
