# Changelog

Grand Tex Avenue – Kediri Stories (TEX CITY). Versions follow `MAJOR.MINOR.PATCH`.
The version lives in `VERSION`, `GAME_VERSION` in `main.js` and the `main.js?v=` tag in `index.html`.

## [1.1.0] - 2026-11-24

### Changed
- One Tex Coin scale everywhere: Rp15.000 = 10 coins for F&B and merch cashier codes, the same as the physical voucher.
- Mission rewards capped at 5 coins (T1 1 … T7 5, B1–B3 1–2).
- Milestones: Jersey OOT-SS25 at 450 coins, Kaos OOT-SS26 at 550 coins.
- OOT Wardrobe prices scaled to the new coin scale (11–37 coins).
- Cashier preview, admin panel and "nominal terlalu kecil" message use the Rp15.000 unit.
- Grand Surya now faces Jl. Dhoho with podium, tower, canopy and kerb sign.
- Aries Motor moved to its real footprint at Jl. Dhoho x Jl. Untung Suropati.

### Added
- `supabase/rescale_koin.sql`: new settings, cashier function on the new unit, and recompute of existing wallets from `game_coin_log`.
- 3D roofs and front props for Tropis and Stasiun Kediri.
- Aries Motor canopy with name boards, striped kerb and potted plant.
- Power poles and cables along the main roads, across the whole city.
- Big LED billboard on Jl. Dhoho; hand-drawn landmark facades.

### Fixed
- Blocked alleys, unreachable mission targets and NPCs clipping through walls.
- Billboard strut no longer stands on the road.
- Removed the broken single pole and cables at Aries.

## [1.0.0] - 2026-11-22

### Added
- Initial import of the game.
