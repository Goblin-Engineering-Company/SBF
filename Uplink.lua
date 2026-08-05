-- Uplink.lua — placeholder for SBF's GEC Uplink integration.
-- Reserved slot in the load order: the addon-side hooks that talk to the GEC Uplink companion app
-- (pairing / version handshake / data hand-off) will live here. Intentionally near-empty for now — just
-- the namespace stub — so the file loads cleanly and can grow later WITHOUT another .toc change (which would
-- force a full client restart). Ships in every build; add real integration code here as it's built.
local _, ns = ...
ns.Uplink = ns.Uplink or {}
