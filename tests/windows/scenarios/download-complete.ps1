# Scenario: Steam's own download-complete toast for Aircar (appid 1073390).
#
# The reference scenario for the whole harness. Aircar is free and installed
# on this machine, so its library art is in Steam's appcache and the toast
# carries a real image; the body carries an em dash, which is what caught the
# helper reading its payload as ANSI (tools/notify-action.ps1 reads UTF-8).
#
# A scenario is a hashtable, not code: it says what to fire and what every
# oracle should then see. run.ps1 owns the order the oracles are consulted.

@{
    Name        = 'download-complete'
    Description = "NotificationStore.TestDownloadComplete(1073390) -> a client toast (type 1)"

    # The dev-door line; frontend/devfire.ts consumes it within ~3s.
    DevFire     = '{"call":"TestDownloadComplete","args":[1073390]}'

    # plugin.log, in the order the frontend writes them.
    DevFireLog  = 'dev-fire: NotificationStore\.TestDownloadComplete\(\[1073390\]\)'
    FromToast   = 'type=1 source=client'

    # The payload the frontend logged (`toast <name> -> {...}`), which is what
    # it handed the backend.
    Title       = '^Download Complete$'
    Body        = 'Aircar'
    Image       = 'steamloopback\.host/assets/1073390/'

    # The toast XML Windows recorded. The image resolves out of Steam's own
    # library cache, so the src is a file:// URI, not the loopback URL.
    ToastTitle  = '^Download Complete$'
    ToastBody   = 'Aircar — Your game is ready to play'
    ToastImage  = 'librarycache/1073390/'
    # Game art is square; only avatars get the circle crop.
    ToastCrop   = ''
}
