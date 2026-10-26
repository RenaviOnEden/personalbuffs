----------------------------------------------------------------------
-- PersonalBuffs (Ashita v4 / HorizonXI)
--
-- Three windows:
--   * Buff box    - buffs you cast (and, if switched on, your party's casts,
--                   marked "Haste (Name)"). One row per buff, lowest timer
--                   first; click a row to see each person and their timer.
--   * Recast box  - your ability and spell recasts, read from game memory.
--   * /pb menu    - per-job checkboxes to hide buffs / recasts, plus the
--                   party on/off switch and per-person checkboxes.
--
-- How buff times are found (best first):
--   1. Real time read from the same buff on you (counts all your gear).
--   2. A real time saved earlier for the same buff + gear setup (you only).
--   3. Base time (durations.lua, from LandSandBoat) + known gear bonuses,
--      shown with "~" because it's a guess.
--
-- Files: personalbuffs.lua (this), durations.lua (base times by spell ID),
--        jobdata.lua (which job gets each spell / ability, level 75 cap;
--        generated from LandSandBoat spell_list.sql / abilities.sql).
--
-- Packet layout and message IDs (230, 266, 420-427, ...) follow
-- LandSandBoat's msg enum. Trusts (spell ID 896+) are never tracked.
----------------------------------------------------------------------
addon.name    = 'personalbuffs'
addon.author  = 'Renavi'
addon.version = '1.0'
addon.desc    = 'Shows time left on buffs you give to yourself and others.'
addon.link    = 'https://github.com/RenaviOnEden/personalbuffs'

require('common')
local chat     = require('chat')
local imgui    = require('imgui')
local settings = require('settings')
local BASE     = require('durations')   -- base times by spell ID (from LandSandBoat)

----------------------------------------------------------------------
-- Settings (saved automatically)
----------------------------------------------------------------------
local defaults = T{
    x            = 250,     -- window position
    y            = 650,
    fallback     = 120,     -- seconds, used when nothing else is known
    durations    = T{},     -- [buff|gear] = real full time read from your own buff
    hidden       = T{},     -- [buff name]  = true when switched off
    hiddenGroups = T{},     -- [group name] = true when switched off
    seen         = T{},     -- [buff name]  = group (fills the settings window)

    -- Recast box (separate window, own position)
    rx           = 250,
    ry           = 450,
    hiddenRecast = T{},     -- [name] = true when switched off
    hiddenRecastGroups = T{}, -- ['Abilities' / 'Spells'] = true when switched off
    seenRecast   = T{},     -- [name] = 'Abilities' or 'Spells'

    -- Party members' buffs (shown in the same box, marked with the caster).
    -- Off by default. Only your party, never alliance or outsiders.
    party        = T{
        enabled   = false,  -- main on / off switch
        hidden    = T{},    -- [caster name] = true when you've turned that person off
        known     = T{},    -- [caster name] = true (people seen, for the menu)
    },

    -- Gear that adds time to buffs. Only used when the real time
    -- can't be read from your own buff (that already counts the gear).
    rules = T{
        T{ item = 'Dilation Ring', buffs = T{ 'Haste', 'Refresh' }, add = 30 },
    },
}
local config = settings.load(defaults)

-- Fills in anything missing from an older settings file, using the defaults.
local function deep_copy(v)
    if type(v) ~= 'table' then return v end
    local out = T{}
    for k, x in pairs(v) do out[k] = deep_copy(x) end
    return out
end

local function fill_missing(cfg, def)
    for k, v in pairs(def) do
        if cfg[k] == nil then
            cfg[k] = deep_copy(v)
        elseif type(v) == 'table' and type(cfg[k]) == 'table' and k ~= 'rules' then
            fill_missing(cfg[k], v)
        end
    end
end
fill_missing(config, defaults)

settings.register('settings', 'pb_settings', function (s)
    if s ~= nil then config = s end
    fill_missing(config, defaults)
end)

----------------------------------------------------------------------
-- Colors (soft, to match the rest of the UI)
----------------------------------------------------------------------
local COL_NAME   = { 0.88, 0.88, 0.88, 1.0 }
local COL_GREEN  = { 0.55, 0.80, 0.55, 1.0 }
local COL_YELLOW = { 0.85, 0.78, 0.45, 1.0 }
local COL_RED    = { 0.82, 0.45, 0.45, 1.0 }
local COL_TARGET = { 0.60, 0.72, 0.86, 1.0 }   -- soft blue for names
local COL_BG     = { 0.05, 0.05, 0.08, 0.70 }
local COL_BORDER = { 0.35, 0.35, 0.40, 0.80 }

local KEEP_AFTER = 5    -- seconds to keep a buff at 0:00

-- Display order of the groups.
local GROUPS = T{ 'Songs', 'Rolls', 'White Magic', 'Black Magic', 'Ninjutsu',
                  'Blue Magic', 'Geomancy', 'Abilities', 'Other' }

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local timers     = T{}   -- [buff name] = { name, group, kind, effect, total, people = { [who] = { exp, est } } }
local pending    = T{}   -- buffs that just landed, waiting for their time
local open       = T{}   -- [buff name] = true when its name list is shown
local press      = nil   -- row clicked on, waiting for mouse release
local showConfig = { false }

-- Party buffs
local partyTimers = T{}  -- [caster] = { [buff name] = row } (same shape as timers)
local partyOpen   = T{}  -- [caster .. '|' .. buff] = true when its name list is shown
local lastRollBy  = T{}  -- [caster] = their most recent roll

local function party_store(caster)
    if partyTimers[caster] == nil then partyTimers[caster] = T{} end
    return partyTimers[caster]
end

----------------------------------------------------------------------
-- Test mode: fake buffs, party buffs and recasts so the boxes can be
-- seen and arranged without casting anything. Real tracking keeps
-- running in the background. Fake data is never saved.
----------------------------------------------------------------------
local testMode = false
local test     = nil   -- { timers, party, recasts, start }

-- One fake row. people = { { name, seconds, guessed? }, ... }
local function test_row(name, group, kind, effect, people, total)
    local row = { name = name, group = group, kind = kind, effect = effect,
                  total = total, people = T{} }
    for _, p in ipairs(people) do
        row.people[p[1]] = { exp = os.time() + p[2], est = p[3] == true, dur = p[2] }
    end
    return row
end

local function build_test()
    local me = 'You'
    local t = T{}
    t['Valor Minuet IV'] = test_row('Valor Minuet IV', 'Songs', 'song', 198,
        { { me, 144 }, { 'Aria', 144 }, { 'Bo', 25 } })
    t['Sword Madrigal']  = test_row('Sword Madrigal', 'Songs', 'song', 199, { { me, 12 } })
    t['Chaos Roll']      = test_row('Chaos Roll', 'Rolls', 'roll', 317, { { me, 290 }, { 'Aria', 290 } }, 11)
    t['Haste']           = test_row('Haste', 'White Magic', 'spell', 33, { { me, 210 } })
    t['Protect III']     = test_row('Protect III', 'White Magic', 'spell', 40,
        { { me, 1790 }, { 'Aria', 1790 }, { 'Bo', 1650, true } })
    t['Reraise']         = test_row('Reraise', 'White Magic', 'spell', 113, { { me, 3590 } })
    t['Utsusemi: Ni']    = test_row('Utsusemi: Ni', 'Ninjutsu', 'spell', 66, { { me, 880 } })

    local party = T{}
    party['Aria'] = T{
        ['Victory March'] = test_row('Victory March', 'Songs', 'song', 214, { { me, 140, true }, { 'Bo', 140, true } }),
        ['Refresh']       = test_row('Refresh', 'White Magic', 'spell', 43, { { me, 150 } }),
        ['Fighter\'s Roll'] = test_row("Fighter's Roll", 'Rolls', 'roll', 310, { { 'Aria', 280 }, { 'Bo', 280 } }, 5),
        -- Same buffs you also cast, to show yours and theirs side by side.
        ['Haste']           = test_row('Haste', 'White Magic', 'spell', 33, { { 'Aria', 200 }, { 'Bo', 200, true } }),
        ['Valor Minuet IV'] = test_row('Valor Minuet IV', 'Songs', 'song', 198, { { 'Bo', 30, true } }),
    }
    party['Bartholomewson'] = T{   -- long name, to show it being shortened
        ["Mage's Ballad II"] = test_row("Mage's Ballad II", 'Songs', 'song', 196, { { me, 95, true } }),
    }

    -- name, group, full recast in seconds (they count down, hit Ready, restart)
    local recasts = {
        { 'Soul Voice', 'Abilities', 3600 }, { 'Nightingale', 'Abilities', 590 },
        { 'Pianissimo', 'Abilities', 15 },  { 'Haste', 'Spells', 20 },
        { 'Valor Minuet IV', 'Spells', 9 },  { 'Cure IV', 'Spells', 40 },
    }
    test = { timers = t, party = party, recasts = recasts, start = os.time() }
end

-- Restarts fake timers that have run out, so test mode keeps going.
local function refresh_test(now)
    local stores = T{ test.timers }
    for _, st in pairs(test.party) do stores:append(st) end
    for _, st in ipairs(stores) do
        for _, row in pairs(st) do
            for _, pp in pairs(row.people) do
                if now > pp.exp + KEEP_AFTER then pp.exp = now + pp.dur end
            end
        end
    end
end

-- Fake recasts in the same shape as read_recasts().
local function test_recasts(now)
    local out = { Abilities = T{}, Spells = T{} }
    local t = now - test.start
    for _, r in ipairs(test.recasts) do
        -- Counts down from the full time, is ready for 8 seconds, then restarts.
        local cycle = r[3] + 8
        local left  = r[3] - (t % cycle)
        if left > 0 then out[r[2]]:append({ name = r[1], left = left }) end
    end
    return out
end

----------------------------------------------------------------------
-- Reading the game clock so buff timers can be turned into seconds
----------------------------------------------------------------------
local VANA_BASE = 0x3C307D70
local timePtr   = ashita.memory.find('FFXiMain.dll', 0,
    '8B0D????????8B410C8B49108D04808D04808D04808D04C1C3', 2, 0)

local function get_stamp()
    if timePtr == nil or timePtr == 0 then return nil end
    local p = ashita.memory.read_uint32(timePtr)
    if p == nil or p == 0 then return nil end
    p = ashita.memory.read_uint32(p)
    if p == nil or p == 0 then return nil end
    return ashita.memory.read_uint32(p + 0x0C)
end

local function seconds_left(raw)
    if raw == nil or raw == 0x7FFFFFFF or raw == -1 then return nil end
    local stamp = get_stamp()
    if stamp == nil then return nil end
    local diff = (raw - (stamp - VANA_BASE) * 60) % 4294967296
    if diff >= 2147483648 then diff = diff - 4294967296 end
    local secs = math.ceil(diff / 60)
    if secs < 1 or secs > 7200 then return nil end
    return secs
end

-- Time left on the newest copy of a buff on yourself.
local function read_self_buff(buffId)
    if buffId == nil or buffId <= 0 then return nil end
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    if player == nil then return nil end
    local buffs = player:GetBuffs()
    local raws  = player:GetStatusTimers()
    if buffs == nil or raws == nil then return nil end

    local best = nil
    for i, id in pairs(buffs) do
        if id == buffId then
            local s = seconds_left(raws[i])
            if s ~= nil and (best == nil or s > best) then best = s end
        end
    end
    return best
end

----------------------------------------------------------------------
-- Names
----------------------------------------------------------------------
local function name_of(serverId)
    local party = AshitaCore:GetMemoryManager():GetParty()
    for i = 0, 17 do
        if party:GetMemberIsActive(i) == 1 and party:GetMemberServerId(i) == serverId then
            local n = party:GetMemberName(i)
            if n ~= nil and n ~= '' then return n end
        end
    end

    local ent = AshitaCore:GetMemoryManager():GetEntity()
    for i = 0, 2303 do
        if ent:GetServerId(i) == serverId then
            local n = ent:GetName(i)
            if n ~= nil and n ~= '' then return n end
        end
    end

    return 'Unknown'
end

-- Players have server IDs below 0x01000000; monsters and NPCs are above.
local function is_player(serverId)
    return serverId > 0 and serverId < 0x01000000
end

----------------------------------------------------------------------
-- Gear checks (read when the action lands, so midcast gear is counted)
----------------------------------------------------------------------
local function equipped(slot)
    local inv = AshitaCore:GetMemoryManager():GetInventory()
    local e   = inv:GetEquippedItem(slot)
    if e == nil then return nil end
    local idx = bit.band(e.Index, 0x00FF)
    if idx == 0 then return nil end
    local cont = bit.rshift(bit.band(e.Index, 0xFF00), 8)
    local item = inv:GetContainerItem(cont, idx)
    if item == nil or item.Id == 0 then return nil end
    return AshitaCore:GetResourceManager():GetItemById(item.Id)
end

local function all_equipped()
    local list = T{}
    for slot = 0, 15 do
        local res = equipped(slot)
        if res ~= nil then list:append(res) end
    end
    return list
end

local SONG_TYPES = T{ 'Minuet', 'Madrigal', 'March', 'Minne', 'Mambo', 'Etude', 'Prelude',
                      'Carol', 'Paeon', 'Ballad', 'Mazurka', 'Hymnus', 'Operetta', 'Pastoral',
                      'Gavotte', 'Round', 'Aubade', 'Fantasia', 'Capriccio', 'Scherzo',
                      'Virelai', 'Sirvente', 'Dirge' }

local function song_type(name)
    for _, t in ipairs(SONG_TYPES) do
        if name:find(t, 1, true) then return t end
    end
    return nil
end

-- Reads "Minuet"+2 / All songs +1 style bonuses from item text.
local function text_bonus(desc, word)
    if desc == nil or word == nil then return 0 end
    local n = desc:lower():match(word:lower() .. '"?%s*%+%s*(%d+)')
    return tonumber(n) or 0
end

-- Works out the gear "signature" and bonus for a buff.
-- sig is used so real times are saved per gear setup (instrument, ring...).
local function gear_info(name, kind)
    local gear    = all_equipped()
    local sig     = T{}
    local ruleAdd = 0
    local bonus   = 0

    if kind == 'song' then
        local inst = equipped(2)   -- range slot
        sig:append(inst ~= nil and inst.Name[1] or 'no instrument')
        local stype = song_type(name)
        for _, res in ipairs(gear) do
            local desc = res.Description and res.Description[1] or nil
            bonus = bonus + text_bonus(desc, stype) + text_bonus(desc, 'All songs')
        end
    end

    for _, rule in ipairs(config.rules or T{}) do
        local applies = false
        for _, b in ipairs(rule.buffs or T{}) do
            if b == name then applies = true end
        end
        if applies then
            for _, res in ipairs(gear) do
                if res.Name[1] == rule.item then
                    ruleAdd = ruleAdd + (rule.add or 0)
                    sig:append(rule.item)
                end
            end
        end
    end

    return table.concat(sig, '+'), ruleAdd, bonus
end

----------------------------------------------------------------------
-- Groups
----------------------------------------------------------------------
local MAGIC_TYPE_GROUP = { [1] = 'White Magic', [2] = 'Black Magic', [4] = 'Ninjutsu',
                           [5] = 'Songs', [6] = 'Blue Magic', [7] = 'Geomancy' }

-- Trusts are spells too; they're never tracked.
-- Trust spell IDs start at 896, and the game marks them as magic type 8.
local function is_trust(id, spell)
    if id ~= nil and id >= 896 then return true end
    return spell ~= nil and spell.Type == 8
end

-- Removes any Trusts that were saved before they were filtered out.
local trustsPurged = false
local function purge_trusts()
    trustsPurged = true
    local rm    = AshitaCore:GetResourceManager()
    local names = {}
    for id = 896, 1100 do
        local sp = rm:GetSpellById(id)
        if sp ~= nil and sp.Name[1] ~= nil and sp.Name[1] ~= '' then names[sp.Name[1]] = true end
    end
    local changed = false
    for _, tbl in ipairs({ config.seen, config.seenRecast, config.hidden, config.hiddenRecast }) do
        for n, _ in pairs(tbl) do
            if names[n] then tbl[n] = nil; changed = true end
        end
    end
    if changed then settings.save() end
end

local function spell_group(spell)
    if spell.Skill == 40 then return 'Songs' end
    if spell.Skill == 39 then return 'Ninjutsu' end
    return MAGIC_TYPE_GROUP[spell.Type] or 'Other'
end

-- Roll ability ID -> roll status ID (to read the roll's time on you).
local function roll_effect(abilityId)
    if abilityId >= 98 and abilityId <= 122 then return 310 + (abilityId - 98) end
    if abilityId >= 302 and abilityId <= 305 then return 335 + (abilityId - 302) end
    if abilityId == 390 then return 339 end
    if abilityId == 391 then return 600 end
    return nil
end

----------------------------------------------------------------------
-- Watch your actions (packet 0x028)
----------------------------------------------------------------------
local SPELL_MSGS = { [230] = true, [266] = true, [205] = true, [319] = true }
local JA_MSGS    = { [100] = true, [266] = true, [319] = true, [320] = true, [441] = true }
local ROLL_MSGS  = { [420] = true, [421] = true }
local DOUBLE_UP  = { [424] = true }
local BUST_MSGS  = { [426] = true, [427] = true }

local function add_pending(p)
    if p.caster ~= nil then
        p.sig, p.ruleAdd, p.bonus = 'party', 0, 0   -- can't see their gear
    else
        p.sig, p.ruleAdd, p.bonus = gear_info(p.name, p.kind)
    end
    p.t = os.time()
    pending:append(p)
end

-- True when the server ID is someone in your party (not you, not alliance).
local function in_party(serverId)
    local party = AshitaCore:GetMemoryManager():GetParty()
    for i = 1, 5 do
        if party:GetMemberIsActive(i) == 1 and party:GetMemberServerId(i) == serverId then
            return true
        end
    end
    return false
end

local function handle_action(e)
    local data    = e.data_raw
    local maxBits = e.size * 8
    local function u(pos, len)
        if pos + len > maxBits then error('short packet') end
        return ashita.bits.unpack_be(data, 0, pos, len)
    end

    local myId  = AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0)
    local actor = u(40, 32)

    -- Who cast it: you, or someone else (only when party tracking is on).
    local caster = nil      -- nil means you
    if actor ~= myId then
        if not config.party.enabled or not is_player(actor) then return end
        if not in_party(actor) then return end   -- party only
        caster = name_of(actor)
    end
    local rollKey = caster or '__me'
    -- Where this caster's rows live (made only when needed).
    local function get_store()
        return (caster == nil) and timers or party_store(caster)
    end

    local tcount = u(72, 6)
    local cat    = u(82, 4)
    local param  = u(86, 32)

    if cat ~= 4 and cat ~= 6 and cat ~= 14 and cat ~= 15 then return end

    -- Read every target / result.
    local results = T{}
    local pos = 150
    for _ = 1, tcount do
        local tid    = u(pos, 32); pos = pos + 32
        local acount = u(pos, 4);  pos = pos + 4
        for _ = 1, acount do
            results:append({ tid = tid, value = u(pos + 27, 17), msg = u(pos + 44, 10) })
            pos = pos + 85
            if u(pos, 1) == 1 then pos = pos + 1 + 37 else pos = pos + 1 end
            if u(pos, 1) == 1 then pos = pos + 1 + 34 else pos = pos + 1 end
        end
    end

    local rm = AshitaCore:GetResourceManager()

    -- Collects the players who got the buff.
    local function gather(msgs)
        local hit, seen, onSelf, effect, value = T{}, {}, false, nil, nil
        for _, r in ipairs(results) do
            if msgs[r.msg] and is_player(r.tid) then
                local who = name_of(r.tid)
                if not seen[who] then
                    seen[who] = true
                    hit:append(who)
                end
                if r.tid == myId then onSelf = true end
                effect = effect or r.value
                value  = value or r.value
            end
        end
        return hit, onSelf, effect, value
    end

    ------------------------------------------------------------------
    -- Spells
    ------------------------------------------------------------------
    if cat == 4 then
        local spell = rm:GetSpellById(param)
        if spell == nil or is_trust(param, spell) then return end
        local hit, onSelf, effect = gather(SPELL_MSGS)
        if #hit == 0 or effect == nil or effect == 0 then return end

        local group = spell_group(spell)
        add_pending({
            name    = spell.Name[1],
            group   = group,
            kind    = (group == 'Songs') and 'song' or 'spell',
            spellId = param,
            effect  = effect,
            onSelf  = onSelf,
            targets = hit,
            caster  = caster,
        })
        return
    end

    ------------------------------------------------------------------
    -- Job abilities (and rolls)
    ------------------------------------------------------------------
    local ability = rm:GetAbilityById(param + 512)
    if ability == nil then return end
    local name = ability.Name[1]

    -- Bust: the roll is gone for everyone.
    for _, r in ipairs(results) do
        if BUST_MSGS[r.msg] then
            local lr = lastRollBy[rollKey]
            if lr ~= nil then
                get_store()[lr] = nil
                if caster == nil then open[lr] = nil end
                -- Also drop the roll if it hasn't been timed yet.
                for i = #pending, 1, -1 do
                    if pending[i].name == lr and pending[i].caster == caster then
                        table.remove(pending, i)
                    end
                end
            end
            return
        end
    end

    -- Double-Up: new total, same timer.
    if name == 'Double-Up' then
        local hit, _, _, total = gather(DOUBLE_UP)
        local lr = lastRollBy[rollKey]
        if lr == nil or #hit == 0 then return end

        -- The roll may still be waiting for its time; update it there too.
        for _, p in ipairs(pending) do
            if p.name == lr and p.caster == caster then p.total = total end
        end

        local row = get_store()[lr]
        if row ~= nil then
            row.total = total
            -- Timer doesn't change. Anyone newly in range gets the roll's
            -- current lowest timer.
            local lowest = nil
            for _, pp in pairs(row.people) do
                if lowest == nil or pp.exp < lowest then lowest = pp.exp end
            end
            for _, who in ipairs(hit) do
                if row.people[who] == nil and lowest ~= nil then
                    row.people[who] = { exp = lowest, est = true }
                end
            end
        end
        return
    end

    -- Rolls
    local hit, onSelf, _, total = gather(ROLL_MSGS)
    if #hit > 0 then
        lastRollBy[rollKey] = name
        add_pending({
            name    = name,
            group   = 'Rolls',
            kind    = 'roll',
            effect  = roll_effect(param),
            total   = total,
            onSelf  = onSelf,
            targets = hit,
            caster  = caster,
        })
        return
    end

    -- Other abilities
    local hit2, onSelf2, effect2 = gather(JA_MSGS)
    if #hit2 == 0 or effect2 == nil or effect2 == 0 then return end
    add_pending({
        name    = name,
        group   = 'Abilities',
        kind    = 'ability',
        effect  = effect2,
        onSelf  = onSelf2,
        targets = hit2,
        caster  = caster,
    })
end

ashita.events.register('packet_in', 'pb_packet', function (e)
    if e.id ~= 0x028 then return end
    pcall(handle_action, e)
end)

----------------------------------------------------------------------
-- Turn pending buffs into timers
----------------------------------------------------------------------
-- Best guess when the real time can't be read. Returns seconds, guessed?
local function estimate(p)
    -- Your saved real times include your gear, so they're only used for you.
    if p.caster == nil then
        local saved = config.durations[p.name .. '|' .. p.sig]
        if saved ~= nil then return saved, false end
    end
    if p.kind == 'song' then
        return math.floor(120 * (1 + 0.1 * (p.bonus or 0))) + p.ruleAdd, true
    end
    if p.kind == 'roll' then
        return 300, true
    end
    if p.spellId ~= nil and BASE[p.spellId] ~= nil then
        return BASE[p.spellId] + p.ruleAdd, true
    end
    return config.fallback + p.ruleAdd, true
end

local function apply(p, expires, est)
    local store = (p.caster == nil) and timers or party_store(p.caster)
    local row = store[p.name]
    if row == nil then
        row = { name = p.name, people = T{} }
        store[p.name] = row
    end
    row.group  = p.group
    row.kind   = p.kind
    row.effect = p.effect
    if p.total ~= nil then row.total = p.total end

    for _, who in ipairs(p.targets) do
        -- A new buff of the same kind replaces the old one on that person
        -- (Protect III replaces Protect II). Songs can stack, so they don't.
        -- This also works across casters (their Protect IV replaces your Protect III).
        if p.kind ~= 'song' and p.effect ~= nil then
            local stores = T{ timers }
            for _, st in pairs(partyTimers) do stores:append(st) end
            for _, st in ipairs(stores) do
                for n, other in pairs(st) do
                    if (st ~= store or n ~= p.name) and other.kind ~= 'song' and other.effect == p.effect then
                        other.people[who] = nil
                    end
                end
            end
        end
        row.people[who] = { exp = expires, est = est }
    end

    if p.caster == nil then
        if config.seen[p.name] ~= p.group then
            config.seen[p.name] = p.group
            settings.save()
        end
    elseif not config.party.known[p.caster] then
        config.party.known[p.caster] = true
        settings.save()
    end
end

local function process_pending(now)
    for i = #pending, 1, -1 do
        local p = pending[i]

        if p.caster ~= nil and not config.party.enabled then
            -- Party tracking was switched off while this was waiting.
            table.remove(pending, i)
        else
            local expires = nil
            local est     = false

            if p.onSelf and now - p.t >= 1 then
                local left = read_self_buff(p.effect)
                if left ~= nil then
                    expires = now + left
                    local full = left + (now - p.t)
                    local key  = p.name .. '|' .. p.sig
                    -- Only save when it really changed (it varies by a second
                    -- from cast to cast, which isn't worth a file write).
                    local old = config.durations[key]
                    if p.caster == nil and (old == nil or math.abs(old - full) > 2) then
                        config.durations[key] = full
                        settings.save()
                    end
                end
            end

            if expires == nil and (not p.onSelf or now - p.t >= 4) then
                local d
                d, est = estimate(p)
                expires = p.t + d
            end

            if expires ~= nil then
                apply(p, expires, est)
                table.remove(pending, i)
            end
        end
    end
end

----------------------------------------------------------------------
-- Draw helpers
----------------------------------------------------------------------
local function time_color(left)
    if left <= 10 then return COL_RED end
    if left <= 30 then return COL_YELLOW end
    return COL_GREEN
end

-- Name column width. It grows to fit the longest spell / song name, which is
-- never shortened. Only other people's names (the caster) get shortened.
local NAME_WIDTH = 20
local MIN_CASTER = 4    -- shortest a caster name is cut to

-- Cuts text to n characters, without a trailing space or dot.
local function cut(text, n)
    if n <= 0 then return '' end
    if #text <= n then return text end
    return (text:sub(1, n):gsub('[%s%.:,\']+$', ''))
end

-- Buff name plus roll total, never shortened.
local function base_label(t)
    local b = t.name
    if t.total ~= nil then b = b .. ' (' .. tostring(t.total) .. ')' end
    return b
end

-- Column width for a set of rows: fits every full buff name and person
-- name, and leaves at least MIN_CASTER letters for caster names.
local function column_width(rows)
    local w = NAME_WIDTH
    for _, t in ipairs(rows) do
        local n = #base_label(t)
        if t.caster ~= nil then n = n + 3 + math.min(#t.caster, MIN_CASTER) end
        if n > w then w = n end
        -- Dropdown lines are indented, so they get one less character.
        for _, e in ipairs(t.entries or {}) do
            local m = #e.who + 1
            if e.caster ~= nil then m = m + 3 + math.min(#e.caster, MIN_CASTER) end
            if m > w then w = m end
        end
    end
    return w
end

-- Dropdown line for one person: "Aria" (your cast) or "Aria (Caster)".
local function entry_label(e, width)
    if e.caster == nil then return e.who end
    local room = math.max(MIN_CASTER, (width - 1) - #e.who - 3)
    return e.who .. ' (' .. cut(e.caster, room) .. ')'
end

-- Full label for a row; the caster name is cut only as much as needed.
local function row_label(t, width)
    local b = base_label(t)
    if t.caster == nil then return b end
    local room = math.max(MIN_CASTER, width - #b - 3)
    return b .. ' (' .. cut(t.caster, room) .. ')'
end

local function fmt_time(left, est)
    local s
    if left >= 3600 then
        s = string.format('%d:%02d:%02d', math.floor(left / 3600), math.floor(left / 60) % 60, left % 60)
    else
        s = string.format('%d:%02d', math.floor(left / 60), left % 60)
    end
    return est and ('~' .. s) or s
end

local function is_hidden(name, group)
    return config.hidden[name] == true or config.hiddenGroups[group] == true
end

local FLAGS = bit.bor(
    ImGuiWindowFlags_NoTitleBar,
    ImGuiWindowFlags_NoResize,
    ImGuiWindowFlags_AlwaysAutoResize,
    ImGuiWindowFlags_NoScrollbar,
    ImGuiWindowFlags_NoCollapse,
    ImGuiWindowFlags_NoFocusOnAppearing,
    ImGuiWindowFlags_NoNav,
    ImGuiWindowFlags_NoSavedSettings
)

local function push_style()
    imgui.PushStyleColor(ImGuiCol_WindowBg, COL_BG)
    imgui.PushStyleColor(ImGuiCol_Border, COL_BORDER)
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 0)
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 1)
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 6, 4 })
end

local function pop_style()
    imgui.PopStyleVar(3)
    imgui.PopStyleColor(2)
end

----------------------------------------------------------------------
-- Recasts
----------------------------------------------------------------------
local RECAST_GROUPS = T{ 'Abilities', 'Spells' }

local TWO_HOURS = {
    [1] = 'Mighty Strikes', [2] = 'Hundred Fists', [3] = 'Benediction', [4] = 'Manafont',
    [5] = 'Chainspell', [6] = 'Perfect Dodge', [7] = 'Invincible', [8] = 'Blood Weapon',
    [9] = 'Familiar', [10] = 'Soul Voice', [11] = 'Eagle Eye Shot', [12] = 'Meikyo Shisui',
    [13] = 'Mijin Gakure', [14] = 'Spirit Surge', [15] = 'Astral Flow', [16] = 'Azure Lore',
    [17] = 'Wild Card', [18] = 'Overdrive', [19] = 'Trance', [20] = 'Tabula Rasa',
    [21] = 'Bolster', [22] = 'Elemental Sforzo',
}

local abilityNames = {}   -- [recast timer id] = name (cached)
local readyUntil   = T{}  -- [name] = { group, until } for "Ready" lines
local lastRecasts  = T{}  -- [name] = group, seen on cooldown last frame

local function ability_name(id)
    if abilityNames[id] ~= nil then return abilityNames[id] end
    local rm = AshitaCore:GetResourceManager()
    local name = nil
    local ab = rm:GetAbilityByTimerId(id)
    if ab ~= nil then name = ab.Name[1] end
    if name == nil or name == '' then
        for x = 0, 2048 do
            local a = rm:GetAbilityById(x)
            if a ~= nil and a.RecastTimerId == id then
                name = a.Name[1]
                break
            end
        end
    end
    name = name or ('Ability ' .. tostring(id))
    abilityNames[id] = name
    return name
end

-- Recast colors: a low timer is good, so the order is reversed.
local function recast_color(left)
    if left <= 10 then return COL_GREEN end
    if left <= 30 then return COL_YELLOW end
    return COL_RED
end

-- Returns { Abilities = list, Spells = list } of { name, left }.
local function read_recasts()
    local out = { Abilities = T{}, Spells = T{} }
    local mm  = AshitaCore:GetMemoryManager()
    local rc  = mm:GetRecast()
    local rm  = AshitaCore:GetResourceManager()
    if rc == nil then return out end

    local job = mm:GetPlayer():GetMainJob()
    for x = 0, 31 do
        local id    = rc:GetAbilityTimerId(x)
        local timer = rc:GetAbilityTimer(x)
        if (id ~= 0 or x == 0) and timer > 0 then
            local name
            if x == 0 then
                name = TWO_HOURS[job] or 'Special'
            else
                name = ability_name(id)
            end
            out.Abilities:append({ name = name, left = math.ceil(timer / 60) })
        end
    end

    for id = 0, 1024 do
        local timer = rc:GetSpellTimer(id)
        if timer > 0 and not is_trust(id, nil) then
            local spell = rm:GetSpellById(id)
            local name  = (spell ~= nil and spell.Name[1] ~= '') and spell.Name[1] or ('Spell ' .. id)
            out.Spells:append({ name = name, left = math.ceil(timer / 60) })
        end
    end
    return out
end

-- Recasts are read 4 times a second, not every frame.
local RECAST_EVERY = 0.25
local recastCache, recastAt = nil, -1

local function draw_recasts(now)
    local ok, cur
    if testMode then
        ok, cur = true, test_recasts(now)
    else
        local c = os.clock()
        if recastCache == nil or c - recastAt >= RECAST_EVERY or c < recastAt then
            local good, res = pcall(read_recasts)
            recastCache = good and res or nil
            recastAt    = c
        end
        ok, cur = recastCache ~= nil, recastCache
    end
    if not ok or cur == nil then return end
    local live = T{}

    -- Note new names for the settings window; spot things that just came off cooldown.
    local changed = false
    for _, g in ipairs(RECAST_GROUPS) do
        for _, r in ipairs(cur[g]) do
            live[r.name] = g
            if not testMode and config.seenRecast[r.name] ~= g then
                config.seenRecast[r.name] = g
                changed = true
            end
        end
    end
    if changed then settings.save() end

    for name, g in pairs(lastRecasts) do
        if live[name] == nil then
            readyUntil[name] = { group = g, untilT = now + KEEP_AFTER }
        end
    end
    lastRecasts = live

    -- Build what to show.
    local show  = { Abilities = T{}, Spells = T{} }
    local count = 0
    for _, g in ipairs(RECAST_GROUPS) do
        if not config.hiddenRecastGroups[g] then
            for _, r in ipairs(cur[g]) do
                if not config.hiddenRecast[r.name] then
                    show[g]:append(r)
                    count = count + 1
                end
            end
        end
    end
    for name, r in pairs(readyUntil) do
        if now > r.untilT or live[name] ~= nil then
            readyUntil[name] = nil
        elseif not config.hiddenRecast[name] and not config.hiddenRecastGroups[r.group] then
            show[r.group]:append({ name = name, left = 0, ready = true })
            count = count + 1
        end
    end
    if count == 0 then return end

    imgui.SetNextWindowPos({ config.rx, config.ry }, ImGuiCond_FirstUseEver)
    push_style()
    -- Name column fits the longest name (nothing is shortened here).
    local rwidth = NAME_WIDTH
    for _, g in ipairs(RECAST_GROUPS) do
        for _, r in ipairs(show[g]) do
            if #r.name > rwidth then rwidth = #r.name end
        end
    end

    if imgui.Begin('personalbuffs_recast', true, FLAGS) then
        local first = true
        for _, g in ipairs(RECAST_GROUPS) do
            local list = show[g]
            if #list > 0 then
                table.sort(list, function (a, b)
                    if a.left ~= b.left then return a.left < b.left end
                    return a.name < b.name
                end)
                if not first then imgui.Dummy({ 0, 4 }) end
                first = false
                for _, r in ipairs(list) do
                    imgui.TextColored(COL_NAME, string.format('%-' .. rwidth .. 's :', r.name))
                    imgui.SameLine(0, 6)
                    if r.ready then
                        imgui.TextColored(COL_GREEN, 'Ready')
                    else
                        imgui.TextColored(recast_color(r.left), fmt_time(r.left, false))
                    end
                end
            end
        end

        -- Remember where the box was dragged to.
        local x, y = imgui.GetWindowPos()
        if (x ~= config.rx or y ~= config.ry) and not imgui.IsMouseDown(0) then
            config.rx, config.ry = x, y
            settings.save()
        end
    end
    imgui.End()
    pop_style()
end

----------------------------------------------------------------------
-- Party buffs helpers
----------------------------------------------------------------------
-- Drops people 5s after their timer ends; returns rows sorted by lowest timer.
local function prune_rows(store, now, openTbl, keyPrefix)
    local list = T{}
    for name, t in pairs(store) do
        local lowest, lowEst = nil, false
        for who, pp in pairs(t.people) do
            if now > pp.exp + KEEP_AFTER then
                t.people[who] = nil
            elseif lowest == nil or pp.exp < lowest then
                lowest, lowEst = pp.exp, pp.est
            end
        end
        if lowest == nil then
            store[name] = nil
            openTbl[keyPrefix .. name] = nil
        else
            t.expires = lowest
            t.est     = lowEst
            list:append(t)
        end
    end
    table.sort(list, function (a, b) return a.expires < b.expires end)
    return list
end

----------------------------------------------------------------------
-- Job catalog: every spell / ability each job gets (level 75 cap).
-- Names come from the game's own data so they match what's shown.
----------------------------------------------------------------------
local JOB_NAMES = { 'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF', 'PLD', 'DRK', 'BST', 'BRD',
                    'RNG', 'SAM', 'NIN', 'DRG', 'SMN', 'BLU', 'COR', 'PUP', 'DNC', 'SCH' }
local catalog = nil   -- [job] = { buffs = {name=group}, recasts = {name=group} }
local spellOrder = {} -- [spell name] = spell ID (used to order tiers)
local songNames  = {} -- [spell name] = true for songs

local function build_catalog()
    local ok, data = pcall(require, 'jobdata')
    catalog = {}
    for job = 1, #JOB_NAMES do
        catalog[job] = { buffs = {}, recasts = {} }
    end
    if not ok or data == nil then return end
    local rm = AshitaCore:GetResourceManager()

    for id, info in pairs(data.spells or {}) do
        local spell = rm:GetSpellById(id)
        if spell ~= nil and not is_trust(id, spell) and spell.Name[1] ~= nil and spell.Name[1] ~= '' then
            local name = spell.Name[1]
            spellOrder[name] = id
            if spell.Skill == 40 then songNames[name] = true end
            for job, _ in pairs(info.jobs) do
                if catalog[job] ~= nil then
                    if info.buff then catalog[job].buffs[name] = spell_group(spell) end
                    catalog[job].recasts[name] = 'Spells'
                end
            end
        end
    end

    for id, info in pairs(data.abilities or {}) do
        local job = info.job
        local ab  = rm:GetAbilityById(id + 512)
        if catalog[job] ~= nil and ab ~= nil and ab.Name[1] ~= nil and ab.Name[1] ~= '' then
            local name = ab.Name[1]
            if info.buff then
                catalog[job].buffs[name] = name:match(' Roll$') and 'Rolls' or 'Abilities'
            end
            local rname
            if ab.RecastTimerId == nil then
                rname = nil
            elseif ab.RecastTimerId == 0 then
                rname = TWO_HOURS[job]
            else
                rname = ability_name(ab.RecastTimerId)
            end
            if rname ~= nil then catalog[job].recasts[rname] = 'Abilities' end
        end
    end
end

-- Turns test mode on / off. Real data is untouched either way.
local function toggle_test()
    testMode = not testMode
    if testMode then build_test() else test = nil end
    open, partyOpen, readyUntil, lastRecasts = T{}, T{}, T{}, T{}
end

-- Menu state
local draw_party_tab   -- defined below
local selJob = nil         -- job shown on the right
local selTab = 'Buffs'     -- 'Buffs' or 'Recasts'
local COL_BTN     = { 0.18, 0.20, 0.26, 0.90 }
local COL_BTN_SEL = { 0.28, 0.38, 0.30, 0.95 }
local CHILD_BORDER = ImGuiChildFlags_Borders or true

-- A button that looks "pressed" when selected.
local function pick_button(label, selected, width)
    imgui.PushStyleColor(ImGuiCol_Button, selected and COL_BTN_SEL or COL_BTN)
    local clicked = imgui.Button(label, { width or 0, 0 })
    imgui.PopStyleColor(1)
    return clicked
end

-- Tier helpers: "Valor Minuet IV" -> "Valor Minuet", "Utsusemi: Ni" -> "Utsusemi".
local ROMAN = { I = 1, II = 2, III = 3, IV = 4, V = 5, VI = 6, VII = 7, VIII = 8 }
local JP    = { Ichi = 1, Ni = 2, San = 3 }
local famOpen = {}   -- [group id .. base] = true when its tiers are shown

-- Songs whose tiers have different names are grouped by song type.
local SONG_FAMILIES = {
    { 'Minuet', 'Minuets' }, { 'Madrigal', 'Madrigals' }, { 'March', 'Marches' },
    { 'Minne', 'Minnes' }, { 'Mambo', 'Mambos' }, { 'Etude', 'Etudes' },
    { 'Prelude', 'Preludes' }, { 'Carol', 'Carols' }, { 'Paeon', 'Paeons' },
    { 'Ballad', 'Ballads' }, { 'Mazurka', 'Mazurkas' }, { 'Hymnus', 'Hymnus' },
    { 'Lullaby', 'Lullabies' }, { 'Elegy', 'Elegies' }, { 'Requiem', 'Requiems' },
    { 'Threnody', 'Threnodies' }, { 'Finale', 'Finales' }, { 'Operetta', 'Operettas' },
    { 'Pastoral', 'Pastorals' }, { 'Gavotte', 'Gavottes' }, { 'Round', 'Rounds' },
    { 'Virelai', 'Virelais' }, { 'Capriccio', 'Capriccios' }, { 'Fantasia', 'Fantasias' },
}

-- Enspells are split by element; this maps the name to the element.
local EN_ELEMENTS = { fire = 'Fire', blizzard = 'Ice', aero = 'Wind', stone = 'Earth',
                      thunder = 'Thunder', water = 'Water', light = 'Light', dark = 'Dark' }
local ELEMENT_ORDER = { Fire = 1, Ice = 2, Wind = 3, Earth = 4, Thunder = 5, Water = 6, Light = 7, Dark = 8 }

-- Returns the family a name belongs to, and a sub-family (or nil).
local function family_name(n)
    if songNames[n] then
        for _, f in ipairs(SONG_FAMILIES) do
            if n:find(f[1], 1, true) then return f[2] end
        end
    end
    if spellOrder[n] ~= nil then
        if n:match('^Bar%l') then return 'Bar Spells' end
        local e = n:match('^En(%l+)')
        if e ~= nil and EN_ELEMENTS[e] ~= nil then
            -- Sub-family is the spell without its tier: Enfire / Enfire II -> Enfire
            return 'Enspells', (n:gsub(' [IVX]+$', ''))
        end
    end
    local base, r = n:match('^(.-) ([IVX]+)$')
    if base ~= nil and ROMAN[r] ~= nil then return base end
    local b2, j = n:match('^(.-): (%a+)$')
    if b2 ~= nil and JP[j] ~= nil then return b2 end
    return n
end

local function tier_rank(n)
    -- Game spell order puts lower tiers first (Hunter's Prelude before Archer's).
    if spellOrder[n] ~= nil then return spellOrder[n] end
    local r = n:match(' ([IVX]+)$')
    if r ~= nil and ROMAN[r] ~= nil then return ROMAN[r] end
    local j = n:match(': (%a+)$')
    if j ~= nil and JP[j] ~= nil then return JP[j] end
    return 1
end

-- A single on/off checkbox for one spell / ability.
local function item_checkbox(n, hidden, id)
    local v = { not hidden[n] }
    imgui.PushStyleColor(ImGuiCol_Text, COL_NAME)
    if imgui.Checkbox(n .. '##i' .. id .. n, v) then
        hidden[n] = (not v[1]) or nil
        settings.save()
    end
    imgui.PopStyleColor(1)
end

-- A family row: one checkbox for all of it, and a clickable name that
-- opens / closes it. Sorts the list by tier. Returns true when open.
local function family_row(label, list, hidden, key)
    table.sort(list, function (a, b) return tier_rank(a) < tier_rank(b) end)

    local shown = 0
    for _, n in ipairs(list) do
        if not hidden[n] then shown = shown + 1 end
    end
    local v = { shown == #list }
    if imgui.Checkbox('##f' .. key, v) then
        for _, n in ipairs(list) do hidden[n] = (not v[1]) or nil end
        settings.save()
    end

    imgui.SameLine(0, 4)
    imgui.PushStyleColor(ImGuiCol_Button, { 0, 0, 0, 0 })
    imgui.PushStyleColor(ImGuiCol_Text, COL_NAME)
    local text = label .. (famOpen[key] and '  -' or '  +')
    if shown > 0 and shown < #list then text = text .. ' (some)' end
    if imgui.SmallButton(text .. '##fb' .. key) then
        famOpen[key] = not famOpen[key] or nil
    end
    imgui.PopStyleColor(2)
    return famOpen[key] == true
end

-- One group: group checkbox, All / None buttons, then items in 2 columns.
local function draw_group(g, names, hidden, hiddenGroups, id)
    local gv = { not hiddenGroups[g] }
    imgui.PushStyleColor(ImGuiCol_Text, COL_GREEN)
    if imgui.Checkbox(g .. '##g' .. id, gv) then
        hiddenGroups[g] = (not gv[1]) or nil
        settings.save()
    end
    imgui.PopStyleColor(1)

    imgui.SameLine(0, 12)
    if imgui.SmallButton('All##a' .. id) then
        for _, n in ipairs(names) do hidden[n] = nil end
        hiddenGroups[g] = nil
        settings.save()
    end
    imgui.SameLine(0, 4)
    if imgui.SmallButton('None##n' .. id) then
        for _, n in ipairs(names) do hidden[n] = true end
        settings.save()
    end

    -- Put tiers together under one name (Valor Minuet -> I, II, III, IV...).
    -- families[base] = { items = list, subs = { [sub] = list } or nil }
    local families, order = {}, T{}
    for _, n in ipairs(names) do
        local base, sub = family_name(n)
        if families[base] == nil then
            families[base] = { items = T{} }
            order:append(base)
        end
        local f = families[base]
        f.items:append(n)
        if sub ~= nil then
            f.subs = f.subs or {}
            f.subs[sub] = f.subs[sub] or T{}
            f.subs[sub]:append(n)
        end
    end

    -- Songs with no other tiers go together under "Other".
    local others = T{}
    local kept   = T{}
    for _, base in ipairs(order) do
        local f = families[base]
        if #f.items == 1 and f.subs == nil and songNames[f.items[1]] then
            others:append(f.items[1])
            families[base] = nil
        else
            kept:append(base)
        end
    end
    order = kept
    table.sort(order)
    if #others > 0 then
        families['Other'] = { items = others, forced = true }
        order:append('Other')   -- always last
    end

    if imgui.BeginTable('t' .. id, 2) then
        for _, base in ipairs(order) do
            local f = families[base]
            imgui.TableNextColumn()

            if #f.items == 1 and not f.forced and f.subs == nil then
                item_checkbox(f.items[1], hidden, id)
            elseif family_row(base, f.items, hidden, id .. base) then
                imgui.Indent(22)
                if f.subs ~= nil then
                    -- Sub-families (Enspells -> Fire -> Enfire, Enfire II).
                    local subs = T{}
                    for sname, _ in pairs(f.subs) do subs:append(sname) end
                    -- Element order: Enfire, Enblizzard, Enaero, Enstone, Enthunder, Enwater, Enlight.
                    local function eorder(x)
                        local e = x:match('^En(%l+)')
                        return ELEMENT_ORDER[EN_ELEMENTS[e or ''] or ''] or 99
                    end
                    table.sort(subs, function (a, b) return eorder(a) < eorder(b) end)
                    for _, sname in ipairs(subs) do
                        local list = f.subs[sname]
                        if #list == 1 then
                            item_checkbox(list[1], hidden, id)
                        elseif family_row(sname, list, hidden, id .. base .. sname) then
                            imgui.Indent(22)
                            for _, n in ipairs(list) do item_checkbox(n, hidden, id) end
                            imgui.Unindent(22)
                        end
                    end
                else
                    for _, n in ipairs(f.items) do item_checkbox(n, hidden, id) end
                end
                imgui.Unindent(22)
            end
        end
        imgui.EndTable()
    end
    imgui.Dummy({ 0, 6 })
end

-- Party tab: main switch, options, and one checkbox per person.
-- The main switch never changes the per-person choices.
draw_party_tab = function()
    local v = { config.party.enabled == true }
    imgui.PushStyleColor(ImGuiCol_Text, COL_GREEN)
    if imgui.Checkbox('Track party buffs (main switch)##pt_main', v) then
        config.party.enabled = v[1]
        if not v[1] then partyTimers = T{} end
        settings.save()
    end
    imgui.PopStyleColor(1)

    imgui.TextColored(COL_NAME, 'Their buffs show in your list as  Haste (Name).')
    imgui.Dummy({ 0, 6 })

    -- People: current party plus anyone seen before.
    local names, seenName = T{}, {}
    local party = AshitaCore:GetMemoryManager():GetParty()
    for i = 1, 5 do
        if party:GetMemberIsActive(i) == 1 then
            local n = party:GetMemberName(i)
            if n ~= nil and n ~= '' and not seenName[n] then
                seenName[n] = true
                names:append(n)
            end
        end
    end
    for n, _ in pairs(config.party.known) do
        if not seenName[n] then
            seenName[n] = true
            names:append(n)
        end
    end
    table.sort(names)

    imgui.TextColored(COL_TARGET, 'People')
    if #names == 0 then
        imgui.TextColored(COL_NAME, 'Nobody yet. Join a party and they show up here.')
        return
    end
    if imgui.BeginTable('pt_people', 2) then
        for _, n in ipairs(names) do
            imgui.TableNextColumn()
            local pv = { not config.party.hidden[n] }
            imgui.PushStyleColor(ImGuiCol_Text, COL_NAME)
            if imgui.Checkbox(n .. '##pp_' .. n, pv) then
                config.party.hidden[n] = (not pv[1]) or nil
                settings.save()
            end
            imgui.PopStyleColor(1)
        end
        imgui.EndTable()
    end
end

local function draw_config()
    if not showConfig[1] then return end
    if catalog == nil then build_catalog() end

    local player = AshitaCore:GetMemoryManager():GetPlayer()
    local main   = player:GetMainJob()
    local sub    = player:GetSubJob()
    if selJob == nil or JOB_NAMES[selJob] == nil then
        selJob = JOB_NAMES[main] ~= nil and main or 1
    end

    imgui.SetNextWindowSize({ 520, 420 }, ImGuiCond_FirstUseEver)
    push_style()
    if imgui.Begin('PersonalBuffs##pbconfig', showConfig, ImGuiWindowFlags_NoCollapse) then

        -- Left: job list (main and sub first).
        -- Wide enough for the longest label ("BRD (main)") plus padding and a scrollbar.
        local tw = 0
        local ok, w = pcall(imgui.CalcTextSize, 'WWW (main)')
        if ok and type(w) == 'number' then tw = w end
        -- Extra room for button padding, the box's own padding and the scroll bar.
        local listWidth = math.max(150, tw + 75)
        imgui.BeginChild('pb_jobs', { listWidth, 0 }, CHILD_BORDER)
        local order = T{}
        if JOB_NAMES[main] ~= nil then order:append({ main, JOB_NAMES[main] .. ' (main)' }) end
        if JOB_NAMES[sub] ~= nil and sub ~= main then order:append({ sub, JOB_NAMES[sub] .. ' (sub)' }) end
        for _, o in ipairs(order) do
            if pick_button(o[2] .. '##top' .. o[1], selJob == o[1], -1) then selJob = o[1] end
        end
        if #order > 0 then imgui.Dummy({ 0, 6 }) end
        for job = 1, #JOB_NAMES do
            if pick_button(JOB_NAMES[job] .. '##job' .. job, selJob == job, -1) then selJob = job end
        end
        imgui.EndChild()

        imgui.SameLine(0, 6)

        -- Right: Buffs / Recasts tabs and the groups.
        imgui.BeginChild('pb_items', { 0, 0 }, CHILD_BORDER)
        if pick_button('Buffs##tabb', selTab == 'Buffs', 80) then selTab = 'Buffs' end
        imgui.SameLine(0, 4)
        if pick_button('Recasts##tabr', selTab == 'Recasts', 80) then selTab = 'Recasts' end
        imgui.SameLine(0, 4)
        if pick_button('Party##tabp', selTab == 'Party', 80) then selTab = 'Party' end
        imgui.SameLine(0, 12)
        if pick_button((testMode and 'Test: on' or 'Test: off') .. '##test', testMode, 80) then
            toggle_test()
        end
        if selTab ~= 'Party' then
            imgui.SameLine(0, 12)
            imgui.TextColored(COL_TARGET, JOB_NAMES[selJob])
        end
        imgui.Dummy({ 0, 4 })

        if selTab == 'Party' then
            draw_party_tab()
            imgui.EndChild()
            imgui.End()
            pop_style()
            return
        end

        local isBuffs = (selTab == 'Buffs')
        local map     = isBuffs and catalog[selJob].buffs or catalog[selJob].recasts
        local groups  = isBuffs and GROUPS or RECAST_GROUPS
        local hidden  = isBuffs and config.hidden or config.hiddenRecast
        local hgroups = isBuffs and config.hiddenGroups or config.hiddenRecastGroups

        local any = false
        for _, g in ipairs(groups) do
            local names = T{}
            for n, grp in pairs(map) do
                if grp == g then names:append(n) end
            end
            if #names > 0 then
                any = true
                table.sort(names)
                draw_group(g, names, hidden, hgroups, selTab .. selJob .. g)
            end
        end
        if not any then
            imgui.TextColored(COL_NAME, 'Nothing for this job.')
        end
        imgui.EndChild()
    end
    imgui.End()
    pop_style()
end

----------------------------------------------------------------------
-- Main list
----------------------------------------------------------------------
ashita.events.register('d3d_present', 'pb_present', function ()
    local now = os.time()
    if not trustsPurged then purge_trusts() end
    process_pending(now)
    draw_config()
    draw_recasts(now)

    -- In test mode the fake stores are shown instead of the real ones.
    local myStore, partyStores = timers, partyTimers
    if testMode then
        refresh_test(now)
        myStore, partyStores = test.timers, test.party
    end
    local partyOn = testMode or config.party.enabled

    -- Build the rows. Everyone's casts of the same buff share one row, and
    -- the dropdown shows who cast it on each person: "Aria (Aria)" means Aria
    -- cast it on herself; no name in brackets means you cast it.
    -- Rolls stay one row per corsair, because each roll has its own total.
    local merged = {}
    local rows   = T{}
    local function add(t, caster)
        local row
        if t.kind == 'roll' and caster ~= nil then
            row = { name = t.name, group = t.group, total = t.total, caster = caster,
                    key = caster .. '|' .. t.name, openTbl = partyOpen, entries = T{} }
            rows:append(row)
        else
            row = merged[t.name]
            if row == nil then
                row = { name = t.name, group = t.group, key = t.name, openTbl = open, entries = T{} }
                merged[t.name] = row
                rows:append(row)
            end
            if caster == nil then row.total = t.total end
        end
        for who, pp in pairs(t.people) do
            row.entries:append({ who = who, exp = pp.exp, est = pp.est, caster = caster })
        end
    end

    -- Drop people 5s after their timer ends; drop buffs with nobody left.
    -- (A shared row's open state is kept, so it isn't cleared here.)
    prune_rows(myStore, now, {}, '')
    for name, t in pairs(myStore) do
        if not is_hidden(name, t.group) then add(t, nil) end
    end
    for caster, store in pairs(partyStores) do
        prune_rows(store, now, partyOpen, caster .. '|')
        if next(store) == nil then
            partyStores[caster] = nil
        elseif partyOn and not config.party.hidden[caster] then
            for _, t in pairs(store) do add(t, caster) end
        end
    end

    -- Each row uses the lowest timer among its people.
    local byGroup = {}
    local shown   = T{}
    for _, row in ipairs(rows) do
        if #row.entries > 0 then
            for _, e in ipairs(row.entries) do
                if row.expires == nil or e.exp < row.expires then
                    row.expires, row.est = e.exp, e.est
                end
            end
            local g = row.group or 'Other'
            byGroup[g] = byGroup[g] or T{}
            byGroup[g]:append(row)
            shown:append(row)
        end
    end
    if #shown == 0 then return end
    local width = column_width(shown)

    imgui.SetNextWindowPos({ config.x, config.y }, ImGuiCond_FirstUseEver)
    push_style()

    if imgui.Begin('personalbuffs', true, FLAGS) then
        local first = true
        for _, g in ipairs(GROUPS) do
            local list = byGroup[g]
            if list ~= nil then
                table.sort(list, function (a, b) return a.expires < b.expires end)

                -- Small gap between groups.
                if not first then imgui.Dummy({ 0, 4 }) end
                first = false

                for _, t in ipairs(list) do
                    local left = t.expires - now
                    if left < 0 then left = 0 end

                    local label   = row_label(t, width)
                    local key     = t.key
                    local openTbl = t.openTbl

                    local _, rowTop = imgui.GetCursorScreenPos()
                    imgui.TextColored(COL_NAME, string.format('%-' .. width .. 's :', label))
                    imgui.SameLine(0, 6)
                    imgui.TextColored(time_color(left), fmt_time(left, t.est))
                    local _, rowBottom = imgui.GetCursorScreenPos()

                    -- The whole row (full box width) counts as the click area.
                    local _, my = imgui.GetMousePos()
                    local rowHovered = imgui.IsWindowHovered() and my >= rowTop and my < rowBottom

                    if rowHovered and imgui.IsMouseClicked(0) then
                        local wx, wy = imgui.GetWindowPos()
                        press = { name = key, x = wx, y = wy }
                    end

                    -- Toggle the name list on click (but not when dragging the box).
                    if press ~= nil and press.name == key and imgui.IsMouseReleased(0) then
                        local wx, wy = imgui.GetWindowPos()
                        if rowHovered and wx == press.x and wy == press.y then
                            openTbl[key] = not openTbl[key] or nil
                        end
                    end

                    -- Dropdown: each person and their own timer, lowest first.
                    -- Someone else's cast shows as "Name (Caster)".
                    if openTbl[key] then
                        table.sort(t.entries, function (a, b) return a.exp < b.exp end)
                        for _, e in ipairs(t.entries) do
                            local pl = e.exp - now
                            if pl < 0 then pl = 0 end
                            imgui.TextColored(COL_TARGET, string.format('   %-' .. (width - 1) .. 's', entry_label(e, width)))
                            imgui.SameLine(0, 6)
                            imgui.TextColored(time_color(pl), fmt_time(pl, e.est))
                        end
                    end
                end
            end
        end
        if imgui.IsMouseReleased(0) then press = nil end

        -- Remember where the box was dragged to.
        local x, y = imgui.GetWindowPos()
        if (x ~= config.x or y ~= config.y) and not imgui.IsMouseDown(0) then
            config.x, config.y = x, y
            settings.save()
        end
    end
    imgui.End()
    pop_style()
end)

----------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------
local function msg(text)
    print(chat.header(addon.name):append(chat.message(text)))
end

-- Matches a typed name to a known buff name (ignores case).
local function find_name(typed)
    local low = typed:lower()
    for n, _ in pairs(config.seen) do
        if n:lower() == low then return n end
    end
    for n, _ in pairs(timers) do
        if n:lower() == low then return n end
    end
    return typed
end

ashita.events.register('command', 'pb_command', function (e)
    local args = e.command:args()
    if #args == 0 or args[1]:lower() ~= '/pb' then return end
    e.blocked = true

    local cmd  = (args[2] or ''):lower()
    local rest = table.concat(args, ' ', 3)

    if cmd == '' or cmd == 'config' then
        showConfig[1] = not showConfig[1]
        return
    end

    if cmd == 'test' then
        toggle_test()
        msg('Test mode: ' .. (testMode and 'on (fake buffs and recasts)' or 'off'))
        return
    end

    if cmd == 'party' then
        config.party.enabled = not config.party.enabled
        if not config.party.enabled then partyTimers = T{} end
        settings.save()
        msg('Party buffs: ' .. (config.party.enabled and 'on' or 'off'))
        return
    end

    if cmd == 'clear' then
        timers     = T{}
        pending    = T{}
        open       = T{}
        readyUntil = T{}
        partyTimers = T{}
        partyOpen   = T{}
        lastRollBy  = T{}
        msg('Buff list cleared.')
        return
    end

    -- /pb hide <name> hides the buff; /pb hide recast <name> hides the recast.
    if (cmd == 'hide' or cmd == 'show') and rest ~= '' then
        local isRecast = false
        local typed    = rest
        if (args[3] or ''):lower() == 'recast' then
            isRecast = true
            typed    = table.concat(args, ' ', 4)
        end
        if typed == '' then
            msg('Use: /pb hide <buff>  or  /pb hide recast <name>')
            return
        end
        local n = find_name(typed)
        if isRecast then
            for r, _ in pairs(config.seenRecast) do
                if r:lower() == typed:lower() then n = r end
            end
        end
        local tbl = isRecast and config.hiddenRecast or config.hidden
        tbl[n] = (cmd == 'hide') or nil
        settings.save()
        msg((cmd == 'hide' and 'Hidden: ' or 'Showing: ') .. n .. (isRecast and ' (recast)' or ''))
        return
    end

    if cmd == 'list' then
        local names = T{}
        for n, v in pairs(config.hidden) do
            if v then names:append(n) end
        end
        for g, v in pairs(config.hiddenGroups) do
            if v then names:append(g .. ' (group)') end
        end
        for n, v in pairs(config.hiddenRecast) do
            if v then names:append(n .. ' (recast)') end
        end
        for g, v in pairs(config.hiddenRecastGroups) do
            if v then names:append(g .. ' (recast group)') end
        end
        table.sort(names)
        if #names == 0 then
            msg('Nothing is hidden.')
        else
            msg('Hidden: ' .. table.concat(names, ', '))
        end
        return
    end

    msg('Commands: /pb (settings window), /pb test (on/off), /pb party (on/off), /pb clear, /pb hide <buff>, /pb show <buff>, /pb hide recast <name>, /pb show recast <name>, /pb list')
end)

ashita.events.register('unload', 'pb_unload', function ()
    settings.save()
end)
