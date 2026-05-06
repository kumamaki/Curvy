place of the curvedz

## install

drag `Curvy.app` from the DMG into `/Applications`. on first launch macOS may say "Curvy is damaged and can't be opened" — the app isn't code-signed, so Gatekeeper quarantines it. clear it once:

    xattr -cr /Applications/Curvy.app
