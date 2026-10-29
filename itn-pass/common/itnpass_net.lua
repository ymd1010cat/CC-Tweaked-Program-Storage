-- itnpass_net.lua -- the one place the ITN-Pass protocol name and modem channel
-- are written down. Deploy as /itnpass_net.lua (next to /sha256.lua): the
-- station and the terminal both read it with dofile("/itnpass_net.lua"), so the
-- two sides cannot drift apart.
--
--   PROTOCOL  the string every modem message carries
--   CHANNEL   the one channel both sides open (1 and 2 belong to Sentinel)

return {
    PROTOCOL = "itnpass_v1",
    CHANNEL  = 33,
}
