# Changelog

Grand Tex Avenue – Kediri Stories (TEX CITY). Versions follow `MAJOR.MINOR.PATCH`.
The version lives in `VERSION`, `GAME_VERSION` in `main.js` and the `main.js?v=` tag in `index.html`.

## [1.3.0] - 2026-11-24

Client revision (REVISI GRAND TEX AVENUE).

### Changed
- Opening card shows the animated Texture logo with "TEXTURE COFFEE PRESENT" instead of OutOfTex.
- Texture Coffee: two table sets left and right of the door, small trees instead of the Garage Sale items, brown box removed. Front repainted after the client photo: 2-storey light sandstone with the red emblem.
- Welcome billboard: Texture logo on the left, "WELCOME TO TEX CITY" on the right, "Jelajahi kota, Temukan ceritamu sendiri" on the black bar.
- The game starts at the Jl. Dhoho crossroads with the client's 3 intro slides; the guide is now Teksan Mahendra.
- Map cut down to the client's play area: Jl. Dhoho crossroads (north), Sumur Bor crossroads (south), Stasiun Kediri (east), Warkop Sopo (west).
- Tropis Coffee moved onto the corner of Jl. Dr. Setiabudi x Jl. Kyai Maja; Setiabudi 6AM fronts Jl. Dr. Setiabudi.

### Added
- Named location pins on the map and radar (Aries Motor, Stasiun Kediri, Grand Surya, SKDP, Tropis, Setiabudi, Astonish, Warkop Sopo, Gie Kie Kong Soe, Setono Gedong).
- Name boards on the roofs of the named buildings.
- Gie Kie Kong Soe temple front.
- Brick gate with a MAKAM SETONO GEDONG sign across Jl. Makam Al Wasil.

## [1.2.0] - 2026-11-24

### Added
- OOT Wardrobe is now a full-screen OUTOFTEX shop inside Texture Coffee: catalogue cards with product shots and prices, plus a separate 3D preview of the player (tap an item to try it on, drag to rotate). The menu never covers the player; on a portrait phone the preview sits on top.
- Opening cutscene after PLAY, following the OOT "Garage Sale 11.11" video: OOT logo, sunset fly-in over Kediri, the player walking up to Texture Coffee, then the Grand Tex Avenue title card. SKIP goes straight to the dialogue.

### Changed
- The game now starts at Texture Coffee's front; respawn and the mission 1 marker moved there too.

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
