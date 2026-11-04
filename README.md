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

On a computer with HTTP enabled (the default), one line fetches everything into `/warehouse`:

```
wget run https://raw.githubusercontent.com/cheployt-sketch/cc-warehouse/main/src/install.lua
```

If the repository is private, use the one-file build instead: `node publish.cjs` packs the whole folder into `dist/warehouse.lua` and puts it in a secret gist (id in `gists.json`, so the URL stays the same), and prints the line to type, of the form `wget run https://gist.githubusercontent.com/<user>/<gist id>/raw/warehouse.lua`. It takes the same `crafter` and `client` arguments and does the same as the installer. It also records its build in `/warehouse/data/build`, and `publish.cjs` writes a `manifest.json` next to it in the gist, so the Control Panel's Updates screen can see when the warehouse computer is behind and update it (the computer downloads the new `warehouse.lua`, runs it and reboots, so `warehouse startup` and `crafter startup` matter there).

It downloads the files listed in `src/files.txt` (regenerate that list with `node test/manifest.cjs` after adding files) and leaves the config, key and data alone, so it also works as an update. The same line with `crafter` after the URL installs the same files and then explains the crafter's steps (on a turtle: pairing and `crafter worker`), and with `client` it explains pairing an app computer; on a turtle `crafter` is the default. Without HTTP, copy the `src` folder to the computer as `/warehouse` (with the cc-bridge: `cc_push src /warehouse`; or carry it on a floppy disk). Then on the computer:

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
- **Screens**: every access point with its chest, monitor and state. Click one to change it (name, chest, monitor, PIN, lock time, text scale, with pickers for the chest and monitor) or remove it; `Add screen` makes a new one. The pickers say what every chest and monitor is already used for (a screen, a stat screen, a Parcel task, the crafter) and list the free ones first. Below the access points come the **stat screens**, monitors that show charts of what the warehouse does (see "Stat screens" below): click one to change which panels it shows, `Add stat screen` makes one.
- **Storage**: the storage types, and every inventory on the network with its role and fill: `Add`, `Exclude`, `Include` or `Remove` per row. Excluding or removing an inventory that still holds items asks whether to move them into the rest of the vault first.
- **Settings**: presets, stack presets, lock time, rescan period, hostname, rednet on/off, log level, your own item categories, and the pairing key.
- **Log**: the service log, scrollable.

Everything is clicked; text fields take typing, Tab moves to the next field, Esc backs out. Every change is written to the config and applied to the running service at once, and the panel says what changed.

## Parcel Service

An app on the API that moves items by itself, task by task. The service hosts it (config `parcels = true`); `parcels` runs it on its own on any paired computer, `parcels list` shows the tasks. Tasks are edited on the panel's **Parcels** page (or in `/warehouse/parcels`), and changes apply at once. Folders keep a long list tidy: `New folder` makes one, a task joins it from its form (the Folder field, with a picker), `Remove folder` puts its tasks back at the top level. What tasks move does not show on the screens' `Recent` tab.

- **Deposit tasks** take items from an inventory into the vault: everything, or only the listed items. Each listed item can have a limit: once the vault holds that many, the task stops taking it (`minecraft:wheat<2000`).
- **Withdraw tasks** send items from the vault to an inventory. Each item has a keep-level (top the inventory up to this many: `minecraft:coal=64`), a per-run cap (`/32`) and a lifetime budget (`#1000`); without a keep-level it sends the per-run amount every run. The container's free space is the last limit, and the message says when it was.
- Every task has an interval, an optional cap per run and lifetime budget, and can be switched off. Several tasks may move the same items, each with its own stats: runs, items moved (per item too), errors, the last run and its message. `Run now` and `Reset stats` are on the task's form.

```
items: deposit   name<limit, name          (all = everything)
       withdraw  name=keep/perRun#total
```

Apps can read any inventory on the network with `vault.inventory(name)`, which is what the Parcel Service uses.

## Crafter

Automated crafting from the vault. `crafter` runs on the warehouse computer next to the service and makes things with a crafty turtle and your furnaces: every ingredient comes out of the vault and every result goes back in, so a recipe with several steps (logs to planks, planks to sticks, sticks and diamonds to a pickaxe) is one job, and whatever a step makes too many of is simply stored. Recipes are laid out in a chest and scanned, edited on the computer's panel while it runs, watched and run from a monitor dashboard, and ordered from the Control Panel (the Crafter app in cc-control-panel).

### Hardware

- **A crafty turtle** (a turtle with a crafting table) with a wired modem on the warehouse's network, and a chest on the network in front of it (or above or below): the turtle takes its ingredients from that chest and drops what it crafted into it (or into a second chest, `output`). It never moves and needs no fuel.
- **A recipe chest** on the network, where you lay recipes out.
- **For smelting:** a chest hoppers take from, in front of your furnaces (`smeltIn`), and a chest hoppers fill with what comes out (`smeltOut`). Fuel is your furnace line's business; a Parcel withdraw task keeps a fuel chest topped up.
- **A monitor** for the dashboard, if you like. The crafter never takes an access point's monitor: one named in its setup is refused when an access point uses it, and without a name it takes the first monitor no access point has.

### Install

On the warehouse computer (the service must run there; `wget run https://raw.githubusercontent.com/cheployt-sketch/cc-warehouse/main/src/install.lua crafter` puts the files there if they are missing):

```
crafter setup turtle=turtle_2 input=minecraft:chest_20 recipeChest=minecraft:chest_19 monitor=right
crafter startup       start on every boot (the file is /startup/crafter.lua)
crafter               start now, in a tab of its own with its panel
```

`crafter setup` alone shows the settings (`turtle`, `input`, `output`, `recipeChest`, `smeltIn`, `smeltOut`, `monitor`, `scale`, `smeltStall`: seconds without output before a smelt or factory step counts as stalled); the panel's Setup page has pickers for them, which say what every chest and monitor is already used for and list the free ones first. The turtle can be named by its name on the network (`turtle_2`: then the crafter can switch it on too) or by its ID.

On the turtle: put the warehouse folder there (`wget run https://raw.githubusercontent.com/cheployt-sketch/cc-warehouse/main/src/install.lua crafter`, or copy it), pair it with a floppy (`warehouse key disk` on the warehouse computer, `wh pair disk` on the turtle), then `crafter worker`. The worker works out which of the chests in front of, above and below it are the service's input and output chests by their contents, so it needs no settings (`crafter worker top bottom` names the sides to fall back on when two empty chests of one size cannot be told apart). The turtle only reaches the chest right in front of, above or below it, and that chest must also be on the warehouse's wired network (a wired modem on it), because the crafter fills it from the vault: a chest the turtle merely sees over the network is no use to it. `crafter startup` on the turtle keeps it going across reboots. After that the turtle keeps itself current: the worker reports the build of its folder, and a service whose folder was installed from the one-file build (it remembers where it came from) sends a turtle on another build there for the same one; the turtle fetches it, checks the build, installs and reboots. A turtle without HTTP or without `crafter startup` is told once and the State line says why.

### Recipes

Lay a step out in the recipe chest the way it goes in a crafting table: the chest's top left 3x3 is the grid (slots 1-3, 10-12 and 19-21), one item per cell, as many as you like of it. Put the result in the top right slot (9) if you have one, with the count one craft gives; otherwise the crafter learns it by crafting once. On the panel, **New recipe**, **Scan craft**, a name, **Save**; or `crafter add Planks` from the shell. A smelting step is laid out the same way with the item to smelt anywhere in the grid: **Scan smelt** (or `crafter add Ingots smelt`). A recipe with several steps: lay the next step out and scan again; steps run in order, and the ^ v x buttons reorder or remove them.

A **factory step** is for machines (Create's and the like) that take several things from several places: lay each input in the 3x3 with the count one unit takes, the result in slot 9 with the count one unit makes, and **Scan factory**. A window opens (later: the `=` button by the step) where each input gets its entry inventory and the step gets one or more collection inventories, all picked from the network; a units-per-batch cap is optional (blank: what a stack of each input allows). Running it, the crafter sends a batch of inputs to the entry inventories, then stores whatever turns up in the collection inventories (everything but the inputs themselves, so byproducts are kept too) and counts the result until the batch is in; what happens between the two is the machines' business. Inputs that are missing are sent when they turn up, machines that give nothing for `smeltStall` seconds are reported as stalled, and two recipes never use the same machines at once. Factory steps sit anywhere in a recipe, before or after crafts and smelts, and as many in a row as you like. A step without a result is learned as soon as the recipe is saved: one craft, or one smelted item, with ingredients from the vault or, failing that, from the recipe chest itself (wherever they lie in it by then).

### Running

- **Run** makes the recipe `count` times (the Run x field); **Order** makes that many of the final item. Orders queue up.
- **Mode always** makes round after round for as long as there are ingredients; **rate** makes `rateCount` items every `rateSeconds` (a period it is still busy with counts as "behind", it is not piled up); **keep** makes the result until the vault holds `keepCount` of it, rests, and goes again once the count has been below that for `keepDelay` seconds (0: at once; the state counts down meanwhile), so sticks until there are 64 in the vault, say, without reacting to a dip that passes; **off** only does what you order.
- **Stop** drops the orders, the run and the mode.

An order is planned backwards from the final item: each earlier step makes only what the later ones need and the vault does not already hold, so a recipe that starts from logs uses the planks and sticks you have before making more. The crafter takes turns between recipes, one turtle round (up to a stack of crafts) at a time, so an always-on recipe never blocks an order. A recipe's state says what it is doing (`step 2/3: crafting 12/64`, `smelting 20/64`, `waiting for Diamond`, `turtle #15 did not answer`, `turtle #15 has no chest on its front side`); an ingredient that runs out makes it wait, not fail. A craft the turtle cannot do (a layout that is no recipe) is a *problem*: the recipe stops with the message until you edit it or order again.

Smelting: the inputs go into the smelter's input chest, and whatever lands in the finish chest is stored every few seconds, whether a smelt is running or not; what the running step is waiting for is counted as it comes. A smelter that gives nothing for `smeltStall` seconds (300) is reported as stalled, and the step goes on as soon as something comes out.

### Where it shows

- **The panel on the computer** (the crafter's tab): Recipes (every recipe, in folders: `New folder` makes one and the folder button on a recipe's form files it there; click a recipe to change, run, order or stop it), Setup, Log.
- **The dashboard** on the monitor: every recipe and what it is doing, in the same folders as the panel (tap a folder to open it; its top row leads back); tap a recipe for its stats and Run, Order (a number pad), Always and Stop. Tapped buttons light up for a moment.
- **The Control Panel** (cc-control-panel's Crafter app): the same from the pocket computer.
- **The shell**: `crafter status`, `crafter list`, `crafter scan`, `crafter add <name> [smelt]`, `crafter order <recipe> <n>`, `crafter run <recipe> [times]`, `crafter stop <recipe>`, `crafter set <recipe> mode=always|rate|keep|off count= rateCount= rateSeconds= keepCount= keepDelay= name= folder=`, `crafter quit`.
- **Apps on the same computer** can ask it the same things: a `crafter_request` event carrying `{ id, op, args }` (ops `status`, `list`, `recipe`, `add`, `scan`, `order`, `run`, `stop`, `set`, `shutdown`) is answered with a `crafter_reply` event `{ id, ok, result or error }`. That is how the Control Panel app reaches it.

Its files are in `/warehouse/data/crafter/`: `config`, `recipes`, `state` (orders in progress and stats, so a reboot carries on where it was) and `log`.

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

- **The list** shows what is stored, coloured by category: blocks light blue, resources yellow, items white, unstackables magenta. The category row (`All`, `Recent`, `Blocks`, `Items`, `Resources`, `Unstack`) filters it; `Recent` lists what was put in or taken out last, newest first; its sort button switches between `New` (what people moved: the screens, the shell, apps) and `Lst` (the last changes by anyone, the Parcel Service and the crafter included). The search box opens an on-screen keyboard above it, with keys as wide as the screen allows and two rows high on a 0.5 text scale, and every key and button lights up for a moment when tapped; `Qty`/`A-Z` switches the order and `<` `>` turn pages. Items with NBT (enchanted tools, named items) show a `*`.
- **Tap an item** and it stays highlighted while the amount panel slides in just above the controls, with the list still visible. Every preset amount and stack multiple moves that many into the chest the moment it is tapped; `Get stack` (twice as tall as the other buttons) moves a stack, or the number typed on the pad once there is one (it then reads `Get 37`); `All` moves everything; `Cancel` closes. If the chest fills up, the message says how many made it. A tap while the last one is still moving items is refused, so a double tap never moves twice, and taps are never lost while the chest is being read.
- **The chest panel** appears by itself above the controls whenever the chest holds something (the chest is read a few times a second, so what you put in shows up at once): a row per stack with a `>` to store just that, and a `Store all` button. Anything you got out and changed your mind about goes back the same way. You never leave the list to use it.
- **Stats** (`Stats` button on narrow monitors; always shown on the right on wide ones): fill bar, slots, items, kinds, fill per storage inventory, top items.
- **Wide monitors** (57 columns or more, which a 0.5 text scale gives on most monitors) show the list and its controls on the left and the stats on the right, with the chest or amount panel at the bottom right.
- **PIN**: without a `pin` a screen never locks (fine for single-player worlds; `warehouse setup` asks). With one, the number pad sits low on the screen; the screen locks again `lockAfter` seconds after the last tap, or only when `Lock` is tapped if `lockAfter` is 0.

## Stat screens

A stat screen is any monitor on the network that shows what the warehouse is doing as gauges, bars and charts: add one on the panel's Screens page (`Add stat screen`: a name, the monitor, the text scale and which panels to show), or in the config:

```lua
stats = {
  { name = "Stats", monitor = "monitor_3", scale = 0.5,
    show = { "fill", "items", "flow", "moves", "top", "kinds", "parcels", "crafter", "screens", "service" } },
}
```

The panels, in the order `show` lists them (leave it out for all of them): `fill` (the storage fill as a gauge, with a bar per storage inventory), `items` (the item total in big digits, kinds and free slots), `flow` (items in storage over the last hours as a column chart), `moves` (what came in and went out, in green above and red below), `top` (the biggest stocks as bars), `kinds` (blocks, items, resources and unstackables as one stacked bar), `parcels` (the Parcel Service: tasks on, moved in the last hour, a row per task), `crafter` (the turtle, recipes running, waiting, queued or idle, made in the last hour, a row per recipe), `screens` (the access points, up or down) and `service` (uptime, rednet, hostname, version). Monitors of any size work: a panel that does not fit goes on the next page and a tap turns the page; wide monitors (57 columns and up, a 0.5 text scale on most) show two columns. As many stat screens as you like, each with its own choice of panels.

The numbers behind the charts come from a point a minute (items, slots, what moved in and out, what the Parcel Service moved and the crafter made), kept for three hours in `/warehouse/data/history`; the crafter is asked for its state every few seconds over its local API, so the panel says "not running" when it is not.

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
| `items` | filter, category, sort, limit, offset | `{ items = {...}, total }`; category: `block`, `item`, `resource`, `unstackable` or `recent` (newest first; sort `recent` for what people moved, the default, or `changed` for the last changes by anyone); each item carries its `category` |
| `item` | item | key, name, displayName, count, maxCount, stacks, locations |
| `count` | item | number (a plain name counts every NBT variant) |
| `withdraw` | item, count, to, toSlot, recent | `{ moved, key, message }` |
| `deposit` | from, slot, slots, item, count, recent | `{ moved, items = { key = n }, message }` |
| `move` | from, fromSlot, to, toSlot, count | `{ moved }` (raw move; storage involved is re-read) |
| `stats`, `inventories`, `peripherals`, `details`, `compact`, `rescan`, `rediscover`, `config`, `access`, `help`, `ping` | | |

Rules worth knowing:

- `withdraw` takes from the smallest stacks first, so partial stacks disappear and full ones stay full. It never gives more than is stored, and reports `message` when the target filled up. Automation passes `recent = false` (the fifth argument of `withdraw`, an option of `deposit`) so that the screens' `Recent` tab keeps showing what people did; the Parcel Service and the crafter do.
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
src/lib/uses.lua      what each inventory and monitor is used for (the pickers)
src/lib/folders.lua   folders for the task and recipe lists
src/lib/stats.lua     stat screens: the collector, the charts and the panels
src/lib/config.lua    config file and inventory roles
src/crafter.lua       the crafter: automated crafting from the vault
src/craft/            its model (recipes), scheduler (engine), turtle line (link), the turtle's side (worker), dashboard (screen) and panel (console)
src/examples/         sink, stock, watch
src/ccryptolib/       ChaCha20-Poly1305, BLAKE3, random (vendored)
```

## Testing

- `node test/check.cjs` compiles every file with Fengari and flags Lua 5.3-only syntax (CC:Tweaked runs Lua 5.2). `node test/run.cjs` runs `test/sim.lua`, the index logic against simulated inventories that behave like CC's (slot-order inserts, stack sizes, drift), and `test/crafter.lua`, the crafter against a simulated vault, turtle and smelter (orders over several steps, always and rate modes, smelting, learning, a turtle that goes away, reboots), and `test/screen.lua`, an access point screen against a simulated monitor, chest and service (taps while the chest is being read, the amount panel, the keyboard and its flash, the Recent order, a stat screen, what the pickers know). `node test/run.cjs crafter` runs just the one. Fengari is taken from the sibling `cc-control-panel/node_modules`.
- The crafter answers `debug.screen`, `debug.touch`, `debug.console` and `debug.click` the same way over its `crafter_request` events. In game, the service accepts two test hooks from programs on the warehouse computer only: `debug.screen` (`{ access = name_or_number }`) returns the text of an access point's monitor, and `debug.touch` (`{ access, x, y }`) taps it. With them a script can drive the screens without standing at the monitor; `vault.try("debug.touch", { x = 5, y = 3 })` from the client library does it.
