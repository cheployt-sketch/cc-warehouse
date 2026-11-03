# cc-warehouse

A storage service for CC:Tweaked. One computer keeps an exact index of your deep storage (Create item vaults, chests, anything with an inventory), drives any number of touch-screen access points, and answers apps on the same computer or on other computers, securely.

```
                    network cable + wired modems
 ┌─────────────┐      ┌───────────────────────┐      ┌──────────────────────┐
 │ item vaults │──────│  warehouse computer   │──────│ access point: chest  │
 │ (storage)   │      │  index + API + screens│      │   + monitor          │
 └─────────────┘      └───────────┬───────────┘      └──────────────────────┘
                                  │ rednet (sealed with the warehouse key)
                       ┌──────────┴──────────┐
                       │ your apps on other  │
                       │ computers / turtles │
                       └─────────────────────┘
```

Status: **v0.1**. Storage index, access point screens (browse, search, amounts, store, stats, PIN lock), the API with local and sealed rednet transports, the `wh` command line and three example apps work and were tested in game.

## What it does

- **Deep storage stays tidy.** Every move names the exact slot, so items go onto existing stacks first and never spread across half-empty slots. `compact` merges what other machines left behind.
- **Exact index, no guessing.** The service reads every storage inventory once at start and keeps the picture up to date from the result of every move. Moves that did less than expected trigger a re-read of that inventory, and a background pass re-reads one inventory a minute, so hoppers and players reaching into a vault cannot make it wrong for long.
- **Fast.** Peripheral calls take a game tick each, but calls started together finish together. Withdrawing 1000 items or storing a full chest is one or two ticks.
- **Access points.** A chest and a monitor each, as many as you like, on the same wired network. The screen lists what is stored, searchable with an on-screen keyboard; tap an item, pick a preset amount or type one, and it lands in the chest. Put things in the chest and one tap stores them all (or one stack). A stats page shows fill and totals. Monitors of any size work; wide ones show the list and the chest side by side.
- **Apps.** `local vault = require("/warehouse/api").connect()` and you have the whole thing: list, count, withdraw to any inventory (even a specific slot), deposit from any inventory, raw moves, stats, and change events. Same code on the warehouse computer and on any other computer with a modem.
- **Multiplayer safe.** Requests over the network are encrypted and authenticated with a key only your computers hold, and cannot be replayed. Screens can ask for a PIN.

## Hardware

- **Storage**: Create item vaults by default. Any block with an inventory works (chests, barrels, drawers, modded storage); set the peripheral types or names in the config.
- **One computer** (an advanced one, so the service can run in a background tab) with a **wired modem**, connected by **network cable** to every storage inventory, every access point chest and monitor, and every inventory apps will use. Put a wired modem on each block and right-click the modems to turn them on. Modems on vaults can be anywhere on the vault.
- **Access points**: a chest (or any inventory) and an advanced monitor, both on the same wired network. Monitors can be any size; text scale is picked automatically (set `scale` in the config to override).
- **Other computers** that run apps need any modem (wired on the same network, or wireless/ender in range) and the warehouse key.

The warehouse computer must be able to reach an inventory to move items into or out of it: everything that receives or gives items sits on the warehouse's wired network. Turtles are not inventories on a wired network, so a crafting turtle takes its ingredients from a chest the service fills (see `examples/stock.lua`).

## Install

Copy the `src` folder to the computer as `/warehouse` (with the cc-bridge: `cc_push src /warehouse`; or carry it on a floppy disk). Then on the computer:

```
/warehouse/warehouse setup      answer the questions: storage types, access points, PINs
/warehouse/warehouse startup    start on every boot, and put wh/warehouse on the path
/warehouse/warehouse            start now (it moves itself into a background tab)
warehouse status                what it holds
```

`warehouse setup` walks through four screens (the network, storage, security, access points), each on a fresh page so nothing scrolls away, and lets you pick a chest and a monitor for each access point. The security step asks whether screens should lock with a PIN at all. The config is a plain file you can also edit by hand, `/warehouse/config`:

```lua
{
  storage = { types = { "create:item_vault" }, names = {}, exclude = {} },
  access = {
    { name = "Main", chest = "minecraft:chest_0", monitor = "monitor_0" },
    { name = "Workshop", chest = "minecraft:barrel_2", monitor = "monitor_3", pin = "2468", scale = 0.5 },
  },
  presets = { 1, 4, 8, 16, 32 },        -- amount buttons
  stackPresets = { 1, 2, 4, 8, 16 },    -- more buttons, in stacks of the item
  lockAfter = 120,                      -- relock time for screens with a pin (0: only via Lock)
  categories = { ["create_new_age:thorium"] = "resource" },  -- fix a category the screens got wrong
  rescanSeconds = 60,                   -- background re-read, 0 to disable
  rednet = true,                        -- serve other computers
  hostname = "vault",                   -- its name on rednet
  logLevel = "info",
}
```

Storage is every inventory on the network whose peripheral type is in `storage.types`, plus `storage.names`, minus `storage.exclude` and the access point chests. Everything else is "free" for apps.

Other commands: `warehouse key` (the pairing key), `warehouse log`, `warehouse stop`.

## The control panel

The warehouse computer's own screen shows a control panel: the service draws it in its tab (`console = true` in the config, the default), and `warehouse ui` opens it in any other tab. Click the shell tab at the top to get back to the command line.

- **Status**: items, kinds, fill per storage inventory, the screens and whether they are up, network and uptime; buttons to reload the config, compact, rescan, and stop the service (click twice).
- **Screens**: every access point with its chest, monitor and state. Click one to change it (name, chest, monitor, PIN, lock time, text scale, with pickers for the chest and monitor) or remove it; `Add screen` makes a new one.
- **Storage**: the storage types, and every inventory on the network with its role and fill: `Add`, `Exclude`, `Include` or `Remove` per row.
- **Settings**: presets, stack presets, lock time, rescan period, hostname, rednet on/off, log level, your own item categories, and the pairing key.
- **Log**: the service log, scrollable.

Everything is clicked; text fields take typing, Tab moves to the next field, Esc backs out. Every change is written to the config and applied to the running service at once, and the panel says what changed.

## Parcel Service

An app on the API that moves items by itself, task by task. The service hosts it (config `parcels = true`); `parcels` runs it on its own on any paired computer, `parcels list` shows the tasks. Tasks are edited on the panel's **Parcels** page (or in `/warehouse/parcels`), and changes apply at once.

- **Deposit tasks** take items from an inventory into the vault: everything, or only the listed items. Each listed item can have a limit: once the vault holds that many, the task stops taking it (`minecraft:wheat<2000`).
- **Withdraw tasks** send items from the vault to an inventory. Each item has a keep-level (top the inventory up to this many: `minecraft:coal=64`), a per-run cap (`/32`) and a lifetime budget (`#1000`); without a keep-level it sends the per-run amount every run. The container's free space is the last limit, and the message says when it was.
- Every task has an interval, an optional cap per run and lifetime budget, and can be switched off. Several tasks may move the same items, each with its own stats: runs, items moved (per item too), errors, the last run and its message. `Run now` and `Reset stats` are on the task's form.

```
items: deposit   name<limit, name          (all = everything)
       withdraw  name=keep/perRun#total
```

Apps can read any inventory on the network with `vault.inventory(name)`, which is what the Parcel Service uses.

## Changing the setup while it runs

Nothing needs a restart. The service re-reads `/warehouse/config` within two seconds of it changing (a half-written file is ignored until it is complete) and applies the differences: screens are started, stopped or re-pointed at another chest or monitor, storage is discovered again, categories are recomputed, the hostname is re-registered, rednet can be switched on or off. Screens that stay keep what you were doing on them.

Edit the file by hand, run `warehouse setup` again, or change one thing at a time:

```
warehouse access                                    the screens, and whether they are up
warehouse access add Shop minecraft:chest_3 monitor_2 pin=4321 scale=0.5
warehouse access set Shop chest=minecraft:barrel_0 pin=      (pin= removes the PIN)
warehouse access remove Shop
warehouse storage                                   the rules, and what counts as storage now
warehouse storage types create:item_vault,minecraft:barrel
warehouse storage add minecraft:chest_5             one more inventory as storage
warehouse storage exclude create:item_vault_3       keep this one out
warehouse set presets=1,8,16,32,64 lockAfter=0 rescanSeconds=30 hostname=wh logLevel=debug
warehouse set category create_new_age:thorium resource
warehouse reload                                    apply a file you edited (or just wait two seconds)
```

Each command saves the config and tells the running service, which answers with what changed. Apps can do the same with `vault.reload()`. Inventories plugged into the network (or unplugged) are noticed by themselves, too.

## The screens

Everything you tap is at the bottom of the monitor, where it is easy to reach; the top row shows the warehouse name, item total and fill (or the last message), and the list fills the space between.

- **The list** shows what is stored, coloured by category: blocks light blue, resources yellow, items white, unstackables magenta. The category row (`All`, `Recent`, `Blocks`, `Items`, `Resources`, `Unstack`) filters it; `Recent` lists what was put in or taken out last, newest first. The search box opens an on-screen keyboard above it; `Qty`/`A-Z` switches the order and `<` `>` turn pages. Items with NBT (enchanted tools, named items) show a `*`.
- **Tap an item** and the amount panel slides in just above the controls, with the list still visible: preset amounts, stack multiples, a number pad and `Get`, `Stack`, `All`, `Cancel` sharing the width as big buttons. `Get` moves the items into the chest; if the chest fills up, the message says how many made it.
- **The chest panel** appears by itself above the controls whenever the chest holds something (the chest is read a few times a second, so what you put in shows up at once): a row per stack with a `>` to store just that, and a `Store all` button. Anything you got out and changed your mind about goes back the same way. You never leave the list to use it.
- **Stats** (`Stats` button on narrow monitors; always shown on the right on wide ones): fill bar, slots, items, kinds, fill per storage inventory, top items.
- **Wide monitors** (57 columns or more, which a 0.5 text scale gives on most monitors) show the list and its controls on the left and the stats on the right, with the chest or amount panel at the bottom right.
- **PIN**: without a `pin` a screen never locks (fine for single-player worlds; `warehouse setup` asks). With one, the number pad sits low on the screen; the screen locks again `lockAfter` seconds after the last tap, or only when `Lock` is tapped if `lockAfter` is 0.

## The command line

```
wh                        status
wh items [filter] [n]     what is stored, most first
wh count <item>
wh item <item>            where its stacks are
wh get <item> <n> <to> [slot]
wh put <from> [slot]
wh move <from> <slot> <to> [slot] [n]
wh compact                merge partial stacks
wh rescan [inventory]     re-read storage
wh peripherals            inventories on the network and their roles
wh help                   every API operation
wh watch                  print changes as they happen
wh pair <key> | pair disk | unpair    on another computer
```

An item can be given as its key (`minecraft:cobblestone`, or `minecraft:diamond_pickaxe@<nbt hash>`), its name, or a unique part of its display name (`deepslate`). Ambiguous names are refused with a list count, never guessed.

## Writing apps

```lua
local wh = require("/warehouse/api")
local vault = wh.connect()   -- this computer's service, or the paired one over rednet

print(vault.count("minecraft:coal"))
local moved, why = vault.withdraw("minecraft:coal", 64, "minecraft:chest_3")      -- into any slot
local moved = vault.withdraw("minecraft:iron_ingot", 9, "minecraft:chest_3", 5)   -- into slot 5
local moved, items, message = vault.deposit("minecraft:chest_3")                  -- everything
vault.deposit("minecraft:chest_3", { slot = 2 })                                  -- one slot
vault.deposit("minecraft:chest_3", { item = "minecraft:cobblestone", count = 100 })

for _, it in ipairs(vault.items({ filter = "ingot", sort = "name" })) do
  print(it.displayName, it.count, it.key, it.maxCount, it.category)
end
local lastMoved = vault.items({ category = "recent", limit = 10 })   -- what went in or out last
local info = vault.item("diamond")    -- count, maxCount, locations = { {inventory, slot, count} }
local st = vault.stats()              -- slots, used, free, items, types, inventories
vault.compact()
vault.peripherals()                   -- { {name, type, size, role = "storage"|"access"|"free"|"excluded"} }

while true do                          -- react instead of polling
  local ev = vault.pullEvent()        -- { type = "change", items = { {key, delta, count}, ... } }
end
```

Every method raises an error with a readable message when the service refuses (`not in storage: x`, `'count' must be a positive number`, `target is a storage inventory`) or does not answer. `vault.try(op, args)` returns `ok, result_or_error` instead, and gives access to every operation by name. `wh help` prints the full list; the main ones:

| op | arguments | result |
| --- | --- | --- |
| `items` | filter, category, sort, limit, offset | `{ items = {...}, total }`; category: `block`, `item`, `resource`, `unstackable` or `recent` (newest first); each item carries its `category` |
| `item` | item | key, name, displayName, count, maxCount, stacks, locations |
| `count` | item | number (a plain name counts every NBT variant) |
| `withdraw` | item, count, to, toSlot | `{ moved, key, message }` |
| `deposit` | from, slot, slots, item, count | `{ moved, items = { key = n }, message }` |
| `move` | from, fromSlot, to, toSlot, count | `{ moved }` (raw move; storage involved is re-read) |
| `stats`, `inventories`, `peripherals`, `details`, `compact`, `rescan`, `rediscover`, `config`, `access`, `help`, `ping` | | |

Rules worth knowing:

- `withdraw` takes from the smallest stacks first, so partial stacks disappear and full ones stay full. It never gives more than is stored, and reports `message` when the target filled up.
- `deposit` tops up partial stacks (fullest first) before opening new slots. When storage is full the leftovers stay in the source and `message` says so. Its `item` filter takes an id, a short name (`oak_planks`) or a display-style spelling, like parcel task lines.
- Operations run one at a time in the order they arrive, from every app and screen together, so two apps cannot race for the same stack.
- Apps on the warehouse computer need no setup. Apps elsewhere: run `wh pair <key>` once on that computer (key from `warehouse key` on the warehouse computer, or `warehouse key disk` plus `wh pair disk` with a floppy). The `/warehouse` folder must be installed there too, since the client library uses its crypto.
- Change events: local apps get them as a `warehouse_event` event (`os.pullEvent("warehouse_event")` works too); over rednet `pullEvent` subscribes by itself.

Examples in `src/examples/`: `sink.lua` (everything dropped in a chest gets stored), `stock.lua` (keeps a chest topped up with an item, a requester), `watch.lua` (prints changes).

## Security

Every computer in range can hear and send on a wireless modem channel, and rednet's sender ID can be faked. So:

- **The warehouse key** (32 random bytes, made on first start, `/warehouse/data/secret`) is the only credential. Requests, replies and events over rednet are encrypted and authenticated with ChaCha20-Poly1305 (via [ccryptolib](https://github.com/migeyel/ccryptolib), vendored, MIT) using that key. Messages carry the time they were made and a random nonce; the service drops anything older than 30 seconds or already seen, so recorded requests cannot be replayed. Every computer in a world shares the host's clock, which is what makes that check reliable.
- Anyone holding the key can use the whole API, including moving items to any inventory on the warehouse's network. Share it only with your own computers. `warehouse key new` makes a new one (pair your computers again).
- Programs running on the warehouse computer itself need no key: they could drive the peripherals directly anyway. `shutdown` and the screen test hooks are only accepted from there.
- Screens are physical: anyone who can tap the monitor and open the chest can take items. Set a `pin` on access points in shared areas. PINs are stored in the config on the warehouse computer.
- Nothing here needs the internet or any outside service.

## How it stays exact

The index holds, per storage inventory, what is in every slot, and per item kind the total and every stack location. A move is planned from the index (which slots to take from or fill), executed as one parallel batch, and the reported counts update the index. A move that moved less than planned marks its inventory for a re-read, which happens before the operation returns. `rescanSeconds` re-reads one inventory per period in the background, and inventories appearing or disappearing on the network are picked up at once. Item details (display name, stack size, tags) are fetched once per kind and cached in `/warehouse/data/items`.

## Project layout

```
src/warehouse.lua     the service and its commands
src/wh.lua            command line
src/api.lua           client library for apps
src/lib/index.lua     storage index and the moves
src/lib/service.lua   the operations (API)
src/lib/transport.lua local events and sealed rednet
src/lib/secure.lua    sealed messages, keys
src/lib/access.lua    access point screens
src/lib/ui.lua        monitor drawing and tap targets
src/lib/config.lua    config file and inventory roles
src/examples/         sink, stock, watch
src/ccryptolib/       ChaCha20-Poly1305, BLAKE3, random (vendored)
```

## Testing

- `node test/check.cjs` compiles every file with Fengari and flags Lua 5.3-only syntax (CC:Tweaked runs Lua 5.2). `node test/run.cjs` runs `test/sim.lua`: the index logic against simulated inventories that behave like CC's (slot-order inserts, stack sizes, drift). Fengari is taken from the sibling `cc-control-panel/node_modules`.
- In game, the service accepts two test hooks from programs on the warehouse computer only: `debug.screen` (`{ access = name_or_number }`) returns the text of an access point's monitor, and `debug.touch` (`{ access, x, y }`) taps it. With them a script can drive the screens without standing at the monitor; `vault.try("debug.touch", { x = 5, y = 3 })` from the client library does it.
