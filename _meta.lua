-- Plugin metadata.
--
-- `name` is read by two consumers that disagree about it. KOReader's own
-- pluginloader takes the plugin name from the directory and explicitly ignores
-- this field as deprecated — but the community App Store plugin uses it for the
-- display name and for detecting a collision with an already-installed plugin,
-- falling back to the directory name only when it is absent. So it stays.
--
-- `version` is shown in the store listing. It has nothing to do with update
-- detection, which compares commit SHAs — every commit to the default branch
-- reads as an available update, whatever this says.
local _ = require("gettext")

return {
    name = "storylines",
    fullname = _("Storylines sync"),
    version = "1.0.0",
    description = _([[
Sends reading progress, session history, book status, ratings and reviews to Storylines.

Pair once with a code from the app; after that it syncs on its own when you close a book or the device sleeps.]]),
}
