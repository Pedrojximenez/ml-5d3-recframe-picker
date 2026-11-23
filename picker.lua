-- Video-only file swap variant of picker v3.4.8; Film Roll shortcut disabled.
-- Mode Picker v3.4.8 (per-preset Dual ISO and recovery ISO settings;
-- gestures, Film Roll guard, journal and apply as v3.4.5)
-- Binary-audited for card lua.mo 6a757158...; see REPORT.md.
-- Diagnostic menus/key observer precede every feature/API check.
local phase, last_error = "bootstrap", ""
-- Last saved cfg evidence only; never infer live count/lastnum from it.
local film_loaded = "unknown"
local key_count, trash_count, last_key = 0, 0, -1
local requests, starts = 0, 0
local last_guard, last_trash_guard = "none", "none"
local dispatch, request_open, report_state
local held_menus = {}
local function fetch(path)
    local ok, value = pcall(function()
        local v = _G
        for field in path:gmatch("[^.]+") do v = v[field] end
        return v
    end)
    if ok then return value end
    return nil
end
-- Always-on journal: key callbacks only enqueue; a non-yielding seconds hook
-- appends at most 64 rows. No second yielding worker shares this Lua state.
-- v3.4.1: every row carries a tier. Ordinary rows stop at the 128KiB cap as
-- before; essential/critical rows (boot, init, keys, hold verdicts, opens,
-- switches) keep a per-boot byte budget past the cap under an absolute hard
-- limit. At boot a file above LOG_ROTATE is renamed to one retained old
-- generation (append-only; never truncated in place), so a saturated file
-- cannot silence the next session.
local BUILD = "PICKER348V"
local LOG_PATH, LOG_LIMIT = "ML/scripts/picker_log.txt", 128*1024
local OLD_PATH, LOG_ROTATE, LOG_HARD = "ML/scripts/picker_old.txt", 64*1024, 512*1024
local EXTRA_ESSENTIAL, EXTRA_CRITICAL = 32*1024, 48*1024 -- per-boot bytes past the cap (critical keeps a 16KiB reserve)
local TIER = {
    BOOT="critical", INIT_END="critical", FAULT="critical", OPENED="critical",
    MODE_SWITCH="critical", SETTING_SWITCH="critical", FILM_GUARD="critical",
    KEY_IN="essential", ARM="essential", RELEASE="essential", REJECT="essential", WOBBLE="essential",
    HOLD_WORKER_END="essential", HOLD_PICKER="essential", HOLD_TASK_CREATE="essential",
    OPEN_REQUEST="essential", OPEN_REJECT="essential", PICKER_TASK_CREATE="essential",
    SWITCH_REJECT="essential", SETTING_REJECT="essential", GUARD_CHANGE="essential",
    DIAGNOSTIC="essential", OBSERVER_REGISTER="essential", BOOT_FILE="essential",
    TRASH_FILM="essential",
}
local log_queue, log_seq, log_bytes, log_dropped = {}, 0, nil, 0
local log_capped, log_error, log_provider = false, "", nil
local log_extra, log_hard, log_marked, log_rotation = 0, false, {}, "pending"
local last_rejection, hold_state = "none", "idle"
local function value(v)
    if type(v)=="string" then return string.format("%q", v:sub(1,400)) .. "(string)" end
    return tostring(v) .. "(" .. type(v) .. ")"
end
local function sample(path)
    local ok, v = pcall(function()
        local t = _G
        for field in path:gmatch("[^.]+") do t=t[field] end
        return t
    end)
    return ok and value(v) or "ERROR:" .. value(v)
end
local function journal(kind, detail, critical, at)
    pcall(function()
        local tier = critical and "critical" or TIER[kind] or "ordinary"
        if log_hard or log_marked[tier] then return end
        if log_capped and tier=="ordinary" then return end
        if #log_queue >= (tier~="ordinary" and 512 or 496) then
            log_dropped=log_dropped+1
            if tier=="ordinary" then return end
            table.remove(log_queue,1) -- bounded; reserve critical outcomes
        end
        log_seq=log_seq+1
        local state = log_provider and log_provider() or "hold=NA"
        log_queue[#log_queue+1] = {tier=tier, kind=kind,
            line=BUILD .. "\t" .. log_seq .. "\t" .. tostring(at or fetch("dryos.ms_clock")) ..
            "\t" .. kind .. "\t" .. tostring(detail or ""):gsub("[\r\n\t]", " "):sub(1,800) ..
            "\tphase=" .. phase .. " active=" .. sample("dryos.config_dir.path") ..
            " lv=" .. sample("lv.running") .. " idle=" .. sample("camera.gui.idle") ..
            " gui=" .. sample("camera.gui.mode") .. " menu=" .. sample("menu.visible") ..
            " rec=" .. sample("movie.recording") .. " " .. state .. "\n"}
    end)
end
local function marker(began, kind, detail)
    return BUILD .. "\t-\t" .. tostring(began) .. "\t" .. kind .. "\t" .. detail .. "\n"
end
local function measure_journal()
    -- Bounded chunked read: counts up to LOG_HARD+1 bytes without one large buffer.
    local f=io.open(LOG_PATH,"rb")
    if not f then return 0 end
    local total=0
    local read_ok, why=pcall(function()
        while total<=LOG_HARD do
            local chunk=f:read(32*1024)
            if type(chunk)~="string" or #chunk==0 then break end
            total=total+#chunk
        end
    end)
    local closed=f:close()
    assert(read_ok and closed, "journal size read/close failed: " .. tostring(why))
    return total
end
local function rotate_journal(began)
    -- Boot-time rotation: one retained generation. The outgoing file is only
    -- appended to and renamed; nothing is truncated or overwritten in place.
    local size=log_bytes
    local ok, result=pcall(function()
        local rename, remove=fetch("dryos.rename"), fetch("dryos.remove")
        assert(type(rename)=="function", "dryos.rename unavailable")
        pcall(function() -- hand-off trace at the tail of the outgoing file (best effort)
            local f=io.open(LOG_PATH,"ab")
            if f then pcall(f.write,f,marker(began,"ROTATE_OUT","bytes=" .. size .. " next=" .. OLD_PATH)); f:close() end
        end)
        local replaced=false
        local old=io.open(OLD_PATH,"rb")
        if old then
            old:close()
            assert(type(remove)=="function", "dryos.remove unavailable")
            assert(remove(OLD_PATH), "remove " .. OLD_PATH .. " failed")
            replaced=true
        end
        assert(rename(LOG_PATH,OLD_PATH), "rename to " .. OLD_PATH .. " failed")
        local left=io.open(LOG_PATH,"rb")
        if left then left:close(); error("source still present after rename") end
        local moved=assert(io.open(OLD_PATH,"rb"), "old generation unreadable after rename")
        moved:close()
        return replaced
    end)
    if ok then
        log_bytes=0; log_rotation="rotated"
        return marker(began,"ROTATED","from=" .. LOG_PATH .. " bytes=" .. size .. " to=" .. OLD_PATH ..
            " replaced_old=" .. tostring(result) .. " threshold=" .. LOG_ROTATE .. "; migration complete, full journal resumes")
    end
    log_rotation="failed"
    return marker(began,"ROTATE_FAILED","bytes=" .. size .. " error=" .. tostring(result):gsub("[\r\n\t]"," "):sub(1,200) ..
        "; continuing in saturated file; essential/critical rows keep per-boot budget")
end
local function flush_journal()
    -- All errors, including optional/missing APIs, are contained; gestures proceed.
    pcall(function()
        if log_error~="" or fetch("movie.recording") == true or #log_queue==0 then return end
        local ok, err = pcall(function()
            local lines, consumed={},math.min(#log_queue,64)
            local began=fetch("dryos.ms_clock")
            if log_bytes==nil then
                log_bytes=measure_journal()
                if log_bytes>LOG_ROTATE then
                    local note=rotate_journal(began)
                    lines[#lines+1]=note;log_bytes=log_bytes+#note
                else log_rotation="not-needed" end
            end
            local function admit(line, tier)
                if log_bytes+#line>LOG_HARD then
                    if not log_marked.hard then
                        log_marked.hard, log_hard=true, true
                        local note=marker(began,"HARD_CAP","absolute " .. LOG_HARD .. "B limit; nothing more this boot; rotation at next boot")
                        lines[#lines+1]=note;log_bytes=log_bytes+#note
                    end
                    return false
                end
                if not log_capped and log_bytes+#line>LOG_LIMIT-1024 then
                    log_capped=true
                    local note=marker(began,"TRUNCATED","128KiB ordinary cap; essential/critical rows continue within per-boot budget " ..
                        EXTRA_ESSENTIAL .. "/" .. EXTRA_CRITICAL .. "B")
                    lines[#lines+1]=note;log_bytes=log_bytes+#note
                end
                if not log_capped then lines[#lines+1]=line;log_bytes=log_bytes+#line;return true end
                if tier=="ordinary" then return false end
                local budget=tier=="critical" and EXTRA_CRITICAL or EXTRA_ESSENTIAL
                if log_extra+#line>budget then
                    if not log_marked[tier] then
                        log_marked[tier]=true
                        local note=marker(began,tier:upper() .. "_CAP","per-boot budget " .. budget .. "B exhausted; later " .. tier .. " rows dropped")
                        lines[#lines+1]=note;log_bytes=log_bytes+#note
                    end
                    return false
                end
                lines[#lines+1]=line;log_bytes=log_bytes+#line;log_extra=log_extra+#line
                return true
            end
            if log_dropped>0 then
                admit(marker(began,"OVERFLOW","dropped=" .. log_dropped .. "; history incomplete"),"essential")
                log_dropped=0
            end
            local real_rows=false
            for i=1,consumed do
                local row=log_queue[i]
                if row.kind~="FLUSH" and row.kind~="SAMPLE" then real_rows=true end
                admit(row.line,row.tier)
            end
            if #lines>0 then
                local f=assert(io.open(LOG_PATH,"ab"),"journal append unavailable")
                local wrote, result=pcall(f.write,f,table.concat(lines))
                local closed=f:close()
                assert(wrote and result and closed,"journal write/close failed")
            end
            for _=1,consumed do table.remove(log_queue,1) end
            local ended=fetch("dryos.ms_clock")
            if real_rows then journal("FLUSH", "begin=" .. tostring(began) .. " end=" .. tostring(ended) .. " duration=" ..
                tostring(type(ended)=="number" and type(began)=="number" and ended-began or "NA") ..
                " pending=" .. #log_queue .. "; file I/O can affect timing") end
        end)
        if not ok then log_error=tostring(err) end -- status only, silent failure
    end)
end
local function rejected(reason, where, at)
    last_rejection=where .. ":" .. reason
    hold_state="rejected"
    journal("REJECT", "phase=" .. where .. " reason=" .. reason, false, at)
end
-- v3.4.8: direction synthesised at ARM (nil = off, v3.4.7 behaviour).
-- Before BOOT so diagnostics and hold_key share the same setting.
local HOLD_WOBBLE_KEY = fetch("KEY.LEFT")
journal("BOOT", "base=648bd3df75b4d7f8a46b8255af2b76bb8512979bb294090c976e526b0bce4828" ..
    " build=v3.4.8 wobble=" .. tostring(HOLD_WOBBLE_KEY) .. " center=" .. sample("KEY.JOY_CENTER") .. " release=" .. sample("KEY.UNPRESS_UDLR"))
-- Diagnostics share the bounded append-only journal; never paint the LCD.
local function diagnostic(line)
    journal("DIAGNOSTIC", line)
end
diagnostic("[picker v3] LOAD")
flush_journal()
local function active_path()
    local p = fetch("dryos.config_dir.path")
    return type(p)=="string" and p or "?"
end
local function report()
    local line = "phase=" .. phase .. " keys=" .. key_count .. " last=" .. tostring(last_key) ..
        " trash=" .. trash_count .. " requests=" .. requests .. " starts=" .. starts ..
        " active=" .. active_path() .. " guard=" .. last_guard .. " trashguard=" .. last_trash_guard .. " error=" .. last_error .. " gui.idle=" .. sample("camera.gui.idle") ..
        " hold=" .. hold_state .. " last-rejection=" .. last_rejection ..
        " journal-error=" .. log_error .. " journal-capped=" .. tostring(log_capped) ..
        " journal-rotation=" .. log_rotation .. " journal-extra=" .. log_extra .. " journal-hard=" .. tostring(log_hard)
    diagnostic("[picker v3] " .. line)
    if report_state then
        local ok, err = pcall(report_state)
        if not ok then diagnostic("[picker v3.3] status unchecked: " .. tostring(err)) end
    end
    flush_journal()
end
local function fault(where, err)
    last_error = where .. ": " .. tostring(err)
    diagnostic("[picker v3] ERROR " .. last_error)
    journal("FAULT", last_error)
end
local function add_menu(spec)
    local new = fetch("menu.new")
    if type(new)~="function" then fault("menu.new", "unavailable; file journal/key observer only"); return false end
    local ok, value = pcall(new, spec)
    journal("MENU_REGISTER", spec.name .. " ok=" .. tostring(ok) .. " value=" .. tostring(value))
    if ok and value then held_menus[#held_menus+1]=value; return true end
    fault("menu.new " .. spec.name, value); return false
end
local status_ok = add_menu {
    parent="Scripts", name="Picker status",
    help="v3.4.8: hold JOY 1.2s: picker, all presets. video TRASH: FILM + reboot. SET: status.",
    select=report,
}
local action_ok = add_menu {
    parent="Scripts", name="Mode Picker",
    help="Open modes; if unavailable, SET reports the fault to picker_log.txt.",
    select=function()
        if request_open then request_open() else report() end
    end,
}
-- Portable TRASH=25 is extracted from this card's luaopen_KEY, not raw BGMT=13.
-- This observer remains installed when feature initialisation fails.
local observer_ok, observer_error = pcall(function()
    local ev = fetch("event")
    assert(ev, "event unavailable")
    ev.keypress = function(k)
        local key_at=fetch("dryos.ms_clock")
        journal("KEY_IN", "key=" .. tostring(k), false, key_at)
        key_count, last_key = key_count+1, k
        if k==25 then trash_count=trash_count+1 end
        last_guard = "lv=" .. tostring(fetch("lv.running")) ..
            ",menu=" .. tostring(fetch("menu.visible")) ..
            ",rec=" .. tostring(fetch("movie.recording"))
        if k==25 then last_trash_guard=last_guard end
        if dispatch then
            local ok, result = pcall(dispatch, k, key_at)
            if ok then journal("KEY_OUT", "key=" .. tostring(k) .. " return=" .. tostring(result)); return result end
            fault("keypress", result)
        end
        journal("KEY_OUT", "key=" .. tostring(k) .. " return=true dispatch=" .. tostring(dispatch~=nil))
        return true
    end
end)
journal("OBSERVER_REGISTER", "ok=" .. tostring(observer_ok) .. " error=" .. tostring(observer_error))
local last_second, sample_ticks = nil, 0
pcall(function()
    event.seconds_clock=function()
        pcall(function()
            local now=fetch("dryos.ms_clock")
            local gap=type(now)=="number" and last_second and now-last_second or nil
            sample_ticks=sample_ticks+1
            -- v3.4.1: heartbeat once a minute plus any abnormal callback gap (was every second).
            if sample_ticks==1 or sample_ticks%60==0 or (gap and gap>1500) then
                journal("SAMPLE", "callback-gap=" .. tostring(gap or "NA") .. " ticks=" .. sample_ticks)
            end
            last_second=now
            flush_journal()
        end)
    end
end)
if not observer_ok then fault("event.keypress", observer_error) end

local function initialise()
    -- Diagnostic menus and file journal are already registered before these checks can fail.
    for _,name in ipairs({"menu.new","menu.block","menu.open","menu.close",
        "task.create","task.yield","display.draw","display.print","display.rect",
        "display.line","display.circle","display.clear",
        "dryos.directory","dryos.rename","dryos.remove","io.open"}) do
        assert(type(fetch(name))=="function", "missing " .. name)
    end
    for _,name in ipairs({"KEY.TRASH","KEY.SET","KEY.Q","KEY.MENU","KEY.UP","KEY.DOWN",
        "KEY.LEFT","KEY.RIGHT","KEY.WHEEL_UP","KEY.WHEEL_DOWN","KEY.WHEEL_LEFT",
        "KEY.WHEEL_RIGHT","KEY.HALFSHUTTER","KEY.FULLSHUTTER","KEY.REC","KEY.LV","KEY.PLAY",
        "COLOR.WHITE","COLOR.BLACK","COLOR.LIGHT_GRAY","COLOR.DARK_GRAY","COLOR.RED"}) do
        assert(type(fetch(name))=="number", "missing " .. name)
    end
    for _,name in ipairs({"FONT.MONO_12","FONT.MONO_20","FONT.SANS_23","FONT.LARGE"}) do
        assert(fetch(name), "missing " .. name)
    end
    assert(type(fetch("FONT.MONO_12.width"))=="function", "missing font width")
    assert(type(fetch("dryos.config_dir.path"))=="string", "missing dryos.config_dir.path")
    assert(type(fetch("movie.recording"))=="boolean", "missing movie.recording")
    assert(type(fetch("lv.running"))=="boolean", "missing lv.running")
    assert(status_ok and action_ok and observer_ok, "diagnostic registration incomplete")
    local TRASH_SHORTCUT = false
local ROOT = "ML/SETTINGS/"
local presets = {
    {folder="FF_HD169",  label="HD",   crop="FF",  aspect="16:9",   status="CONT"},
    {folder="FF_OG32",   label="OG",   crop="FF",  aspect="3:2",    status="CONT"},
    {folder="S35_4K239", label="4K",   crop="S35", aspect="2.39:1", status="BURST"},
    {folder="S35_35K239",label="3.5K", crop="S35", aspect="2.39:1", status="LIMIT"},
    {folder="MFT_3K239", label="3K",   crop="MFT", aspect="2.39:1", status="CONT"},
    {folder="MFT_3K169", label="3K",   crop="MFT", aspect="16:9",   status="LIMIT"},
    {folder="S16_HD169", label="HD",   crop="S16", aspect="16:9",   status="CONT"},
    {folder="S16_HD239", label="HD",   crop="S16", aspect="2.39:1", status="CONT"},
    {folder="S16_105048",label="48p",  crop="S16", aspect="16:9",   status="LIMIT"},
}
local opened, busy, committed, worker_running = false, false, false, false
local hold_worker_running = false
local focus, current, message = 1, "", ""
local selected = 1
local page, setting_values, settings = 1, {}, {}
local queue, blocked = {}, false
local W, B, G, D, R = COLOR.WHITE, COLOR.BLACK, COLOR.LIGHT_GRAY, COLOR.DARK_GRAY, COLOR.RED
local small, large = FONT.MONO_12, FONT.LARGE
local RETURN_LINE = "PHOTO: hold JOY 1.2s = picker; TRASH = native film shelf."
local ENTER_LINE = "JOY 1.2s + release: picker on every preset; video TRASH stays with Canon; reboot required."
local launch_candidate, launch_film
local screen -- saved/error presentation survives navigation after commit
local last_draw_at = 0

local function exists(path)
    local dir, name = path:match("^(.*[/])([^/]+)$")
    for _, p in ipairs(dryos.directory(dir):files()) do
        if p:match("([^/]+)$"):lower() == name:lower() then return true end
    end
    return false
end

local function read_file(path, limit)
    limit = limit or 128 -- marker/settings reads retain the binary-safe size cap
    local f = assert(io.open(path, "rb"), "Cannot read " .. path)
    local data, read_error = f:read(limit+1)
    local ok = f:close()
    assert(not read_error, "Read failed: " .. path)
    assert(ok, "Cannot close " .. path)
    data = data or "" -- EOF on an empty marker is valid; I/O errors are not.
    assert(#data <= limit, "Unexpected large settings file: " .. path)
    return data
end

local function write_file(path, data, limit)
    local f = assert(io.open(path, "wb"), "Cannot write " .. path)
    local ok = f:write(data)
    local closed = f:close() -- always close, including write failure
    assert(ok and closed, "Write/close failed: " .. path)
    assert(read_file(path, limit) == data, "Read-back failed: " .. path)
end

local function remove_file(path)
    if exists(path) then assert(dryos.remove(path), "Cannot remove " .. path) end
    assert(not exists(path), "File still exists: " .. path)
end

local META = ROOT .. "PCKMETA.TXT"
local function video_markers_clear(except)
    for _, p in ipairs(presets) do
        if p.folder ~= except and dryos.directory(ROOT .. p.folder).exists and
           exists(ROOT .. p.folder .. "/filmroll.en") then
            return false, p.folder
        end
    end
    return true, "none"
end

-- These are file facts, never claims about the module's live internal worker.
local function invariants(folder, film)
    local base = ROOT .. folder .. "/"
    return not exists(ROOT .. "filmroll.en") and exists(ROOT .. "filmroll.en.off")
       and read_file(ROOT .. "filmroll.en.off") == ""
       and exists(base .. "filmroll.en") == film
       and exists(base .. "filmroll.en.off") == (not film)
       and read_file(base .. (film and "filmroll.en" or "filmroll.en.off")) == ""
       and video_markers_clear()
end

local function recovery_state()
    local residue = exists(META)
    for i=1,5 do
        residue = exists(ROOT .. "PCK" .. i .. ".BAK") or
                  exists(ROOT .. "PCK" .. i .. ".NEW") or residue
    end
    if not residue then return "none" end
    local folder = exists(ROOT .. "CURRENT.SET") and read_file(ROOT .. "CURRENT.SET") or ""
    local known = folder == "PHOTO_FILM"
    for _, p in ipairs(presets) do if p.folder == folder then known = true end end
    local placement = known and invariants(folder, folder == "PHOTO_FILM") or false
    local journal = exists(META) and read_file(META, 2048) or ""
    local recorded = journal:find("\nCOMMITTED ", 1, true) and "COMMITTED" or "PARTIAL"
    -- Even COMMITTED residue requires manual review: never discard recovery evidence.
    return recorded .. ";disk-invariants=" .. tostring(placement) .. ";manual recovery required"
end

report_state = function()
    local mo, off = exists("ML/MODULES/filmroll.mo"), exists("ML/MODULES/filmroll.mo.off")
    local module = mo and (off and "CONFLICT (.mo + .mo.off)" or "present .mo") or
                   (off and "parked .mo.off" or "missing")
    local path = active_path()
    diagnostic("[picker v3.3] module=" .. module .. "; native-runtime-readiness=unchecked")
    diagnostic("[picker v3.3] active-preset .en=" .. tostring(exists(path:gsub("/+$", "") .. "/filmroll.en")))
    diagnostic("[picker v3.3] root .en absent=" .. tostring(not exists(ROOT .. "filmroll.en")) ..
          "; root .en.off present=" .. tostring(exists(ROOT .. "filmroll.en.off")))
    local clear, stray = video_markers_clear()
    diagnostic("[picker v3.3] video .en clear=" .. tostring(clear) .. "; stray=" .. stray ..
          "; recovery=" .. recovery_state())
    diagnostic("[picker v3.4.0] " .. RETURN_LINE)
    diagnostic("[picker v3.4.0] " .. ENTER_LINE)
end
-- Check interrupted transactions at startup without clearing or changing any file.
local recovery_ok, recovery = pcall(recovery_state)
if not recovery_ok or recovery ~= "none" then
    diagnostic("[picker v3.3] recovery=" .. tostring(recovery) .. "; apply frozen")
end

-- Five-file transaction. Backups and a recovery map precede every commit.
-- DryOS has no verified multi-file atomic transaction/fsync in this API.
-- Synchronous errors roll back; sudden power loss requires manual recovery.
local function save_selection(folder, film)
    assert(dryos.directory(ROOT .. folder).exists, "Missing preset: " .. folder)
    assert(exists(ROOT .. folder .. "/magic.cfg"), "Missing preset magic.cfg")
    if film then
        assert(exists("ML/MODULES/filmroll.mo"), "Film Roll module parked/missing; unpark before apply")
        assert(not exists("ML/MODULES/filmroll.mo.off"), "Film Roll .mo.off present; unpark before apply")
    end
    local clear, stray = video_markers_clear(folder)
    assert(clear, "Stray video filmroll.en: " .. stray .. "; recover before apply")
    assert(recovery_state() == "none", "Recovery files present; see REPORT.md")
    local ops = {
        {path=ROOT .. "filmroll.en", data=false},
        {path=ROOT .. "filmroll.en.off", data=""},
        {path=ROOT .. folder .. "/filmroll.en", data=false},
        {path=ROOT .. folder .. "/filmroll.en.off", data=""},
        {path=ROOT .. "CURRENT.SET", data=folder}, -- no newline or NUL
    }
    if film then
        ops[3].data=""; ops[4].data=false
    end
    local meta = META
    assert(not exists(meta), "Recovery files present; see REPORT.md")
    for i, op in ipairs(ops) do
        op.bak, op.tmp = ROOT .. "PCK" .. i .. ".BAK", ROOT .. "PCK" .. i .. ".NEW"
        assert(not exists(op.bak) and not exists(op.tmp), "Recovery files present; see REPORT.md")
        op.old = exists(op.path) and read_file(op.path) or false
        if i < 5 then assert(op.old == false or op.old == "", "Nonempty Film Roll marker") end
    end
    local changed = false
    local ok, err = pcall(function()
        local map = {"PICKER33 " .. folder,
            "INTENT root.en=ABSENT root.off=PRESENT",
            "INTENT active.en=" .. (film and "PRESENT" or "ABSENT") ..
                " active.off=" .. (film and "ABSENT" or "PRESENT"),
            "INTENT video.en=NONE"}
        for i, op in ipairs(ops) do
            map[#map+1] = i .. " " .. (op.old == false and "ABSENT" or "PRESENT")
            if op.old ~= false then write_file(op.bak, op.old) end
            if op.data ~= false then write_file(op.tmp, op.data) end
        end
        local prepared = table.concat(map, "\n")
        write_file(meta, prepared, 2048)
        assert(not movie.recording, "Recording started; cancelled")
        changed = true
        for _, op in ipairs(ops) do
            remove_file(op.path)
            if op.data ~= false then
                assert(dryos.rename(op.tmp, op.path), "Cannot install " .. op.path)
                assert(read_file(op.path) == op.data, "Installed file mismatch")
            end
        end
        assert(read_file(ROOT .. "CURRENT.SET") == folder and invariants(folder, film),
               "Committed marker invariant mismatch")
        local record = "\nCOMMITTED " .. folder .. " root.en=ABSENT root.off=PRESENT active.en=" ..
            (film and "PRESENT" or "ABSENT") .. " active.off=" ..
            (film and "ABSENT" or "PRESENT") .. " video.en=NONE"
        -- Append preserves the prepared map; close + read-back is the checked Lua API.
        local f = assert(io.open(meta, "ab"), "Cannot append transaction journal")
        local wrote = f:write(record)
        local closed = f:close()
        assert(wrote and closed, "Cannot close COMMITTED journal")
        assert(read_file(meta, 2048) == prepared .. record, "COMMITTED read-back failed")
    end)
    if not ok and changed then
        local restored = pcall(function()
            for _, op in ipairs(ops) do
                if op.old == false then remove_file(op.path) else write_file(op.path, op.old) end
            end
        end)
        if not restored then error("RECOVERY REQUIRED: PCKMETA.TXT / REPORT.md") end
    end
    local cleaned = pcall(function()
        for _, op in ipairs(ops) do remove_file(op.tmp); remove_file(op.bak) end
        remove_file(meta)
    end)
    if not ok then error(tostring(err)) end
    committed = true
    assert(cleaned, "Saved; cleanup failed. Manual reboot; see REPORT.md")
end

local function text(s, x, y, font, color, width)
    display.print(s, x, y, font or small, color or G, B, width or (720-x))
end

local function dot(x, y, color)
    display.circle(x, y, 1, color, color)
end

local function tag(s, x, y, color)
    local width = small:width(s)+8
    display.rect(x-width, y, width, 15, color)
    text(s, x-width+4, y+1, small, color, width-6)
end

local function status(s, right, y)
    local width = FONT.MONO_20:width(s)
    local x = right-width-12
    if s == "CONT" then display.circle(x+3, y+6, 3, G, G)
    elseif s == "BURST" then display.rect(x, y+3, 6, 6, G, G)
    else
        for row=0,6 do
            local half = math.floor(row/2)
            display.line(x+3-half, y+row+2, x+3+half, y+row+2, G)
        end
    end
    text(s, x+12, y, FONT.MONO_20, W, width)
end

-- Native values and config keys audited for the pinned Danne build.
-- WB/SS have writable Canon APIs but no verified native per-preset persistence.
local setting_specs = {
    {label="BIT DEPTH", menu="Movie", entry="Bitdepth", file="crop_rec.cfg",
     key="crop.bitdepth", choices={"14 bit","8 bit","9 bit","10 bit","12 bit"}, default=4},
    {label="HDR VIDEO", menu="Shoot", entry="HDR video", file="magic.cfg",
     key="hdrv.en", choices={"OFF","ON"}, default=0},
    {label="DUAL ISO", menu="Expo", entry="Dual ISO", file="dual_iso.cfg",
     key="isoless.hdr", choices={"OFF","ON"}, default=0, dual=true},
    {label="RECOVERY ISO", menu="Dual ISO", entry="Recovery ISO", file="dual_iso.cfg",
     key="isoless.iso", min=-12, choices={"-6 EV","-5 EV","-4 EV","-3 EV","-2 EV","-1 EV",
        "+1 EV","+2 EV","+3 EV","+4 EV","+5 EV","+6 EV","100","200","400","800","1600","3200","6400"},
     default=3, dual=true},
}
local CFG_LIMIT = 65536
local function native_value(spec)
    local get=fetch("menu.get")
    if type(get)~="function" or type(fetch("menu.set"))~="function" then return nil end
    local ok,v=pcall(get,spec.menu,spec.entry,0)
    if ok and type(v)=="number" and v%1==0 and v>=(spec.min or 0) and v<(spec.min or 0)+#spec.choices then return v end
end
local function read_setting_cfg(data, spec, replacement)
    assert(not data:find("%z"), "NUL in config")
    local escaped=spec.key:gsub("%.","%%.")
    local found,old=0,spec.default
    local out=data:gsub("([^\n]*)(\n?)", function(line, nl)
        local v=line:match("^%s*" .. escaped .. "%s*=%s*([+-]?%d+)%s*$")
        if v then
            found=found+1; old=tonumber(v)
            if replacement~=nil then
                local cr=line:sub(-1)=="\r" and "\r" or ""
                return spec.key .. " = " .. replacement .. cr .. nl
            end
        elseif line:match("^%s*" .. escaped .. "%s*=") then error("Malformed config key: " .. spec.key) end
        return line .. nl
    end)
    assert(found<=1, "Duplicate config key: " .. spec.key)
    assert(old>=(spec.min or 0) and old<(spec.min or 0)+#spec.choices, "Config value outside audited range")
    if replacement~=nil and found==0 then
        local nl=data:find("\r\n",1,true) and "\r\n" or "\n"
        out=data .. ((#data>0 and data:sub(-1)~="\n") and nl or "") .. spec.key .. " = " .. replacement .. nl
    end
    assert(#out<=CFG_LIMIT, "Config too large")
    return old,out
end
local function setting_context(index)
    local movie_mode=fetch("MODE.MOVIE")
    if setting_specs[index].dual then
        -- These settings reboot too: do not bypass the saved Film Roll evidence.
        if current=="PHOTO_FILM" and tonumber(film_loaded)~=0 then return false end
        local mode,iso=fetch("camera.mode"),fetch("camera.iso.raw")
        return type(movie_mode)=="number" and type(mode)=="number" and
            (current=="PHOTO_FILM" and mode~=movie_mode or current~="PHOTO_FILM" and mode==movie_mode) and
            type(iso)=="number" and iso>0
    end
    if type(movie_mode)~="number" or fetch("camera.mode")~=movie_mode then return false end
    if index==1 then
        local get=fetch("menu.get")
        if type(get)~="function" then return false end
        local ok,v=pcall(get,"Movie","Presets",0)
        return ok and type(v)=="number" and v>0
    end
    local iso=fetch("camera.iso.raw")
    return type(iso)=="number" and iso>0
end
local function load_settings()
    settings,setting_values={},{}
    for i,spec in ipairs(setting_specs) do
        local v=native_value(spec)
        local ok,disk=pcall(function()
            assert(current~="PHOTO_FILM" or spec.dual, "Video preset required")
            assert(dryos.directory(ROOT .. current).exists, "Unknown runtime preset")
            local known=spec.dual and current=="PHOTO_FILM"
            for _,p in ipairs(presets) do if p.folder==current then known=true end end
            assert(known, "Unknown runtime preset")
            local path=ROOT .. current .. "/" .. spec.file
            return read_setting_cfg(exists(path) and read_file(path,CFG_LIMIT) or "",spec)
        end)
        settings[i]=ok and v~=nil and disk==v and setting_context(i)
        setting_values[i]=v or spec.default
    end
    -- Both fields share one module cfg; reject any live/disk disagreement.
    settings[3],settings[4]=settings[3] and settings[4],settings[3] and settings[4]
end
local function save_setting(index)
    local spec=assert(setting_specs[index])
    assert(settings[index] and setting_context(index), "Setting unavailable or camera context changed")
    assert(not movie.recording and lv.running and camera.gui.idle, "Idle LiveView required")
    assert((current~="PHOTO_FILM" or spec.dual) and dryos.config_dir.path:match("/SETTINGS/([^/]+)/?$")==current,
        "Runtime preset changed")
    assert(read_file(ROOT .. "CURRENT.SET")==current, "Pending preset; restart first")
    assert(recovery_state()=="none", "Recovery files present; see REPORT.md")
    local photo=current=="PHOTO_FILM"
    assert(invariants(current,photo), "Film Roll marker invariant mismatch")
    local target=ROOT .. current .. "/" .. spec.file
    local old=exists(target) and read_file(target,CFG_LIMIT) or false
    local before,data=read_setting_cfg(old or "",spec,setting_values[index])
    local live=native_value(spec)
    assert(live==before, "Runtime/disk mismatch; reopen settings")
    if spec.dual then
        for i=3,4 do
            assert(native_value(setting_specs[i])==read_setting_cfg(old or "",setting_specs[i]),
                "Dual ISO runtime/disk mismatch; reopen settings")
        end
    end
    assert(setting_values[index]~=before, "Choose a different value with LEFT / RIGHT")
    local current_bytes=read_file(ROOT .. "CURRENT.SET")
    local bak,tmp=ROOT .. "PCK1.BAK",ROOT .. "PCK1.NEW"
    local prepared="PICKER340_SETTING " .. current .. "\nTARGET " .. target ..
        "\nKEY " .. spec.key .. "\nOLD " .. (old==false and "ABSENT" or "PRESENT") ..
        "\nVALUE " .. before .. " -> " .. setting_values[index]
    local changed,touched=false,false
    local ok,err=pcall(function()
        if old~=false then write_file(bak,old,CFG_LIMIT) end
        write_file(tmp,data,CFG_LIMIT)
        write_file(META,prepared,2048)
        assert(not movie.recording and camera.gui.idle and lv.running, "Camera became busy")
        assert(dryos.config_dir.path:match("/SETTINGS/([^/]+)/?$")==current and
            read_file(ROOT .. "CURRENT.SET")==current_bytes, "Preset changed during staging")
        if spec.dual then assert(setting_context(index), "Dual ISO context changed during staging") end
        touched=true
        assert(menu.set(spec.menu,spec.entry,setting_values[index])==true, "Native setting rejected")
        assert(native_value(spec)==setting_values[index], "Native setting read-back mismatch")
        if spec.dual then
            assert(setting_context(index), "Dual ISO context changed during native apply")
            local sibling=setting_specs[index==3 and 4 or 3]
            assert(native_value(sibling)==read_setting_cfg(old or "",sibling), "Dual ISO pair changed during apply")
        end
        assert(not movie.recording, "Recording started; cancelled")
        assert(dryos.config_dir.path:match("/SETTINGS/([^/]+)/?$")==current and
            read_file(ROOT .. "CURRENT.SET")==current_bytes, "Preset changed during native apply")
        changed=true
        remove_file(target)
        assert(dryos.rename(tmp,target), "Cannot install setting config")
        assert(read_file(target,CFG_LIMIT)==data, "Config read-back mismatch")
        assert(read_file(ROOT .. "CURRENT.SET")==current_bytes and invariants(current,photo),
            "Setting changed preset/markers")
        local record="\nCOMMITTED SETTING " .. spec.key .. "=" .. setting_values[index]
        local f=assert(io.open(META,"ab"),"Cannot append setting journal")
        local wrote=f:write(record);local closed=f:close()
        assert(wrote and closed and read_file(META,2048)==prepared .. record, "COMMITTED read-back failed")
    end)
    if not ok then
        local restored=pcall(function()
            if touched then
                assert(menu.set(spec.menu,spec.entry,live)==true and native_value(spec)==live,
                    "Native rollback failed")
            end
            if changed then
                if old==false then remove_file(target) else write_file(target,old,CFG_LIMIT) end
            end
        end)
        if not restored then error("RECOVERY REQUIRED: setting runtime/config; retain PCK files") end
    else committed=true end
    local cleaned=pcall(function() remove_file(tmp);remove_file(bak);remove_file(META) end)
    if not ok then error(tostring(err)) end
    assert(cleaned,"Saved; cleanup failed. Manual reboot; see REPORT.md")
end

-- Console ownership lasts only for this picker session; unknown state restores shown.
local console_was_visible, console_captured = nil, false
local function hide_console()
    if not console_captured then
        console_was_visible = fetch("console.visible")
        console_captured = true
    end
    pcall(function() console.hide() end)
end
local function restore_console()
    if not console_captured then return end
    pcall(function()
        if console_was_visible == false then console.hide() else console.show() end
    end)
end

local function draw()
    if not opened then return end
    -- Reclaim the complete canvas after console/foreign notification painting.
    if fetch("console.visible") == true then hide_console() end
    last_draw_at = dryos.ms_clock
    display.draw(function()
        display.rect(0, 0, 720, 480, B, B)
        if screen then
            text(screen.kind=="saved" and "SAVED" or "APPLY FAILED", 24, 72, large, W, 672)
            text(screen.target, 24, 154, FONT.SANS_23, W, 672)
            if screen.kind=="saved" then
                text(screen.detail, 24, 224, FONT.SANS_23, W, 672)
                text(RETURN_LINE, 24, 382, small, G, 672)
            else
                -- Bounded lines fit the actual bitmap font; keep the complete
                -- reason in the journal. No notify_box can cover this screen.
                local reason=screen.detail:gsub("[\r\n\t]", " ")
                for row=0,5 do
                    local part=reason:sub(row*46+1,(row+1)*46)
                    if part~="" then text(part,24,218+row*24,FONT.MONO_20,W,672) end
                end
                text("ARROWS: BACK / SELECT    SET: RETRY",24,382,small,G,672)
            end
            text("PUSH JOY: CLOSE", 576, 455, small, G, 120)
            return
        end
        if page==1 and current=="PHOTO_FILM" then
            -- Same tag as video tiles; the roll state shares FILM_EVIDENCE's boot snapshot.
            -- Keep both rows inside the existing header; no live cfg reads here.
            text("MODE 1/2", 24, 10, small, W, 80)
            tag("NOW PHOTO_FILM", 234, 8, R)
            local loaded = tonumber(film_loaded)
            text("FILM: " .. (loaded==1 and "LOADED" or loaded==0 and "NOT LOADED" or "UNKNOWN"),
                24, 28, small, W, 210)
        else
            text(page==1 and "MODE 1/2" or "SETTINGS 2/2", 24, 12, FONT.SANS_23, W, 210)
        end
        text(TRASH_SHORTCUT and "HOLD=PICKER / TRASH=FILM" or "SCRIPTS: MODE PICKER", 240, 19, small, G, 195)
        -- term12.rbf is 8 px wide: widen header controls to fit real glyphs.
        -- Focused header buttons: filled white with dark text; unfocused: outline with light text.
        if focus==0 then display.rect(443, 8, 83, 25, W, W)
        else display.rect(443, 8, 83, 25, G) end
        display.print("ML MENU", 456, 15, small, focus==0 and B or W, focus==0 and W or B, 62)
        if focus==-1 then display.rect(535, 8, 161, 25, W, W)
        else display.rect(535, 8, 161, 25, G) end
        display.print(page==1 and "SETTINGS >" or "< MODES", 547, 15, small, focus==-1 and B or W, focus==-1 and W or B, 141)
        display.line(24, 44, 696, 44, D)
        if page==2 then
            for i,spec in ipairs(setting_specs) do
                local y=54+(i-1)*76
                display.rect(24,y,672,70,focus==i and W or D)
                text(spec.label,44,y+12,FONT.SANS_23,W,280)
                text(settings[i] and spec.choices[setting_values[i]-(spec.min or 0)+1] or "UNAVAILABLE",
                    390,y+12,FONT.SANS_23,W,280)
                local hint=settings[i] and "LEFT / RIGHT: CHOOSE    SET: SAVE" or
                    "Needs movie/manual ISO or crop ON; config must match"
                if spec.dual and not settings[i] then
                    hint=current=="PHOTO_FILM" and tonumber(film_loaded)~=0 and "ROLL LOADED / UNKNOWN: POWER OFF/ON; NO SAVE" or
                        "Needs Dual ISO menu, manual ISO and matching cfg"
                end
                text(hint,44,y+48,small,G,632)
            end
            text("DUAL: RAW photo / RAW video only; saved per preset.",24,370,small,G,672)
            text("PAIR: Canon primary ISO + recovery ISO. HDR = frame alternation.",24,392,small,G,672)
            text(focus==0 and "SET = OPEN ML MENU; NO RESTART" or focus==-1 and "SET = PAGE 1/2; NO RESTART" or
                not settings[focus] and "UNAVAILABLE: NO APPLY / NO RESTART" or
                "SET = SAVE + REBOOT; fallback: OFF/ON",24,424,FONT.MONO_20,W,672)
            text("PUSH JOY: CLOSE",576,455,small,G,120)
            return
        end
        for i, p in ipairs(presets) do
            local x, y = 24+((i-1)%3)*227, 54+math.floor((i-1)/3)*114
            local color = focus==i and W or D
            display.rect(x, y, 218, 110, color)
            if focus==i then display.rect(x+1, y+1, 216, 108, W) end
            -- v3.4.5: the running preset (dryos.config_dir, i.e. the folder this boot
            -- loaded from CURRENT.SET) carries a red NOW tag; the static NEW badge is gone.
            if p.folder==current then tag("NOW", x+210, y+89, R) end
            text(p.label, x+14, y+28, FONT.SANS_23, W, 190)
            local crop_width = FONT.SANS_23:width(p.crop)
            text(p.crop, x+14, y+66, FONT.SANS_23, W, 70)
            local ax = x+14+math.max(36, crop_width+19)
            dot(ax, y+75, G)
            text(p.aspect, ax+10, y+70, small, G, 112)
            text(p.folder, x+14, y+89, small, G, 122)
            status(p.status, x+206, y+7)
        end
        local target=focus==-1 and "SETTINGS 2/2" or focus==0 and "ML MENU" or
            presets[focus==-2 and selected or focus].folder
        text(((focus==0 or focus==-1) and "SET = OPEN  " or "SET = APPLY  ") .. target,
            24, 424, FONT.MONO_20, W, 672)
        text(focus<=0 and focus~=-2 and "No apply / no restart" or
            "Auto reboot; if still here: power OFF/ON",24,406,small,G,672)
        -- Focused footer pill: filled white with dark text and dark arrow; unfocused: outline with light text.
        if focus==-2 then display.rect(267, 447, 243, 26, W, W)
        else display.rect(267, 447, 243, 26, G) end
        display.print("SET", 280, 454, small, focus==-2 and B or W, focus==-2 and W or B, 32)
        local lc = focus==-2 and B or W
        display.line(309, 460, 322, 460, lc)
        display.line(318, 457, 322, 460, lc); display.line(318, 463, 322, 460, lc)
        display.print("APPLY SELECTION", 332, 454, small, focus==-2 and B or W, focus==-2 and W or B, 171)
        if focus==9 then text("Canon: 720p60 required", 24, 455, small, G, 236) end
        text("PUSH JOY: CLOSE", 576, 455, small, G, 120)
    end)
end

local function close_picker(stock_menu, reason, by)
    if launch_candidate then rejected(reason or "picker-closed-before-action", "open"); launch_candidate=nil end
    journal("Q_CLOSE", "stock_menu=" .. tostring(stock_menu) .. " by=" .. tostring(by or reason or "key"))
    opened = false
    queue = {}
    restore_console()
    console_captured = false
    if blocked then menu.block(false); blocked=false end
    -- One transition cleanup; never a background overlay or recording redraw loop.
    display.clear()
    if stock_menu then menu.open() end
end

local function saved_screen(target)
    screen={kind="saved",target=target,detail="POWER OFF / ON TO APPLY"}
    -- Only advertise reboot while a real API call / existing 3s window is active.
    -- Keep console ownership until the picker actually closes.
    local reboot=fetch("camera.reboot")
    if type(reboot)=="function" then
        screen.detail="REBOOTING..."
        draw()
        local reboot_ok = pcall(reboot)
        if reboot_ok then task.yield(3000) end
        screen.detail="POWER OFF / ON TO APPLY"
    end
    draw()
end

local function apply(folder, film)
    if committed then return end -- the saved screen remains authoritative
    if movie.recording then
        screen={kind="error",target=film and "FILM ROLL" or folder,
            detail="Stop recording before applying."}
        journal("SWITCH_REJECT", "target=" .. folder .. " recording-in-progress")
        return
    end
    -- All rebooting routes converge here: tile SET, video TRASH and JOY hold.
    -- Save config now invokes module saves but cannot report module write failure
    -- to Lua. Do not accept a core magic.cfg timestamp as proof of Film Roll save.
    -- Use the existing bounded boot evidence (previous saved value), never count.
    if active_path():match("/PHOTO_FILM/?$") and tonumber(film_loaded)==1 then
        screen={kind="error",target=film and "FILM ROLL" or folder,
            detail="ROLL LOADED: POWER OFF/ON TO SWITCH."}
        journal("FILM_GUARD", "target=" .. folder .. " film.loaded=" .. film_loaded ..
            " source=last-saved-cfg action=reject; POWER OFF/ON TO SWITCH", true)
        journal("SWITCH_REJECT", "target=" .. folder .. " film-roll-loaded")
        if launch_candidate then rejected("film-roll-loaded", "apply"); launch_candidate=nil end
        flush_journal()
        return
    end
    busy = true
    local ok, err = pcall(save_selection, folder, film)
    busy = false
    local target=film and "FILM ROLL" or folder
    if not ok then
        message=tostring(err):gsub("^.-:%d+: ", "")
        screen={kind="error",target=target,detail=message}
        journal("SWITCH_REJECT", "target=" .. folder .. " error=" .. value(err))
        if launch_candidate then rejected("apply=" .. value(err), "apply"); launch_candidate=nil end
        return
    end
    journal("MODE_SWITCH", "target=" .. folder .. " film=" .. tostring(film) ..
        " candidate=" .. tostring(launch_candidate) .. "; saved/verified; reboot pending", true)
    if launch_candidate then hold_state="switched"; launch_candidate=nil end
    for _=1,9 do flush_journal() end
    saved_screen(target)
end

-- Header: 0=ML MENU, -1=page switch; body 1..9; footer -2.
local function navigate(k)
    if page==2 and not committed then
        screen=nil
        if (k==KEY.LEFT or k==KEY.RIGHT) and focus>0 and settings[focus] then
            local spec=setting_specs[focus]
            local n,minimum=#spec.choices,spec.min or 0
            setting_values[focus]=(setting_values[focus]-minimum+(k==KEY.RIGHT and 1 or -1))%n+minimum
        elseif k==KEY.UP or k==KEY.WHEEL_UP or k==KEY.WHEEL_LEFT then
            focus=focus>1 and focus-1 or focus==1 and -1 or #setting_specs
        elseif k==KEY.DOWN or k==KEY.WHEEL_DOWN or k==KEY.WHEEL_RIGHT then
            focus=focus<=0 and 1 or focus<#setting_specs and focus+1 or -1
        elseif focus<=0 and (k==KEY.LEFT or k==KEY.RIGHT) then focus=focus==0 and -1 or 0 end
        return
    end
    message = ""
    if not committed then screen=nil end
    if k==KEY.WHEEL_RIGHT or k==KEY.WHEEL_DOWN or k==KEY.WHEEL_LEFT or k==KEY.WHEEL_UP then
        local order = {0,-1,1,2,3,4,5,6,7,8,9,-2}
        local index=1
        for i,v in ipairs(order) do if v==focus then index=i end end
        local delta=(k==KEY.WHEEL_LEFT or k==KEY.WHEEL_UP) and -1 or 1
        focus=order[(index-1+delta)%#order+1]
    elseif focus>0 then
        if k==KEY.LEFT then focus=(focus-2)%9+1
        elseif k==KEY.RIGHT then focus=focus%9+1
        elseif k==KEY.UP then focus=focus<=3 and (focus==1 and 0 or -1) or focus-3
        elseif k==KEY.DOWN then focus=focus>=7 and -2 or focus+3 end
    elseif focus==-2 then
        if k==KEY.UP then focus=selected
        elseif k==KEY.DOWN then focus=0 end
    else
        if k==KEY.LEFT or k==KEY.RIGHT then focus=focus==0 and -1 or 0
        elseif k==KEY.DOWN then focus=focus==0 and 1 or 3
        elseif k==KEY.UP then focus=-2 end
    end
    if focus>0 then selected=focus end
end

local function run_picker()
    journal("PICKER_WORKER_START", "candidate=" .. tostring(launch_candidate))
    starts=starts+1
    diagnostic("[picker v3] WORKER start=" .. starts)
    local ok, err = pcall(function()
        if not opened then return end
        if menu.visible then menu.close() end -- sleeps in API: worker only
        if not opened then return end
        if movie.recording then close_picker(false,"movie.recording=true"); return end
        hide_console()
        menu.block(true); blocked=true
        if launch_film then apply("PHOTO_FILM",true) end
        draw()
        journal("OPENED", "candidate=" .. tostring(launch_candidate) .. " first-draw-ok", true)
        if launch_candidate and not launch_film then hold_state="opened"; launch_candidate=nil end
        while opened do
            if movie.recording then close_picker(false,"movie.recording=true"); break end
            local k=table.remove(queue,1)
            if k then
                -- v3.4.4: the joystick centre press is the advertised, Q-free close.
                -- TRASH/Q remain modal-consumed closes; MENU still hands over to ML.
                if k==KEY.JOY_CENTER then close_picker(false,nil,"joy-center")
                elseif k==KEY.TRASH or k==KEY.Q then close_picker(false,nil,k==KEY.Q and "q" or "trash")
                elseif k==KEY.MENU then close_picker(true,nil,"menu")
                elseif k==KEY.SET then
                    if committed then -- saved/recovery screen cannot apply again
                    elseif focus==0 then close_picker(true,nil,"set-ml-menu")
                    elseif focus==-1 then
                        page=page==1 and 2 or 1;focus=page==2 and 1 or selected
                        if page==2 then load_settings() end
                    elseif page==2 then
                        busy=true
                        local ok_setting,setting_err=pcall(save_setting,focus)
                        busy=false
                        if ok_setting then
                            journal("SETTING_SWITCH",setting_specs[focus].key .. "=" .. setting_values[focus],true)
                            for _=1,9 do flush_journal() end
                            saved_screen(setting_specs[focus].label .. ": " .. setting_specs[focus].choices[setting_values[focus]-(setting_specs[focus].min or 0)+1])
                        else
                            screen={kind="error",target=setting_specs[focus].label,detail=tostring(setting_err)}
                            journal("SETTING_REJECT",tostring(setting_err))
                        end
                    else apply(presets[focus==-2 and selected or focus].folder, false) end
                else navigate(k) end
                draw()
            end
            if opened then
                -- No notification callback exists in this Lua API. A bounded
                -- repaint also repairs foreign notify-box drawing after expiry.
                if fetch("console.visible")==true or dryos.ms_clock-last_draw_at>=300 then draw() end
                task.yield(60)
            end
        end
    end)
    if not ok then
        -- Release the global menu-redraw gate even after draw/API errors.
        if launch_candidate then rejected("picker-worker-error=" .. value(err),"open"); launch_candidate=nil end
        pcall(close_picker, false)
        fault("worker", err)
    end
    journal("PICKER_WORKER_END", "ok=" .. tostring(ok) .. " error=" .. tostring(err))
    worker_running=false
end

local function open_picker(enter_film, candidate)
    requests=requests+1
    journal("OPEN_REQUEST", "film=" .. tostring(enter_film) .. " candidate=" .. tostring(candidate))
    local guard=opened and "opened=true" or worker_running and "worker_running=true" or
        hold_worker_running and "hold_worker_running=true" or movie.recording and "movie.recording=true"
    if guard then
        journal("OPEN_REJECT", guard)
        if candidate then rejected(guard,"open") end
        return false
    end
    current = dryos.config_dir.path:match("/SETTINGS/([^/]+)/?$") or ""
    focus, message, selected = 1, "", 1 -- focus follows runtime preset, not CURRENT.SET
    if not committed then screen=nil end
    for i,p in ipairs(presets) do if p.folder==current then focus=i; selected=i end end
    launch_candidate, launch_film=candidate, enter_film
    page=1
    queue, opened, worker_running = {}, true, true
    local ok, err=pcall(task.create, run_picker)
    journal("PICKER_TASK_CREATE", "ok=" .. tostring(ok) .. " error=" .. tostring(err))
    if not ok then
        if candidate then rejected("task.create=" .. value(err),"open"); launch_candidate=nil end
        opened=false; worker_running=false; fault("task.create", err)
        return false
    end
    return true
end

-- Physical 5D3 events: raw 0x3e -> JOY_CENTER=11; raw 0x35 ->
-- UNPRESS_UDLR=20 (translated before the same raw UNPRESS_DP=34).
-- Film Roll consumes shelf keys before Lua. Its synthetic -19 route is blocked.
assert(type(KEY.JOY_CENTER)=="number", "missing KEY.JOY_CENTER")
assert(type(KEY.UNPRESS_UDLR)=="number", "missing KEY.UNPRESS_UDLR")
assert(type(dryos.ms_clock)=="number", "missing dryos.ms_clock")
assert(type(camera.gui.idle)=="boolean", "missing camera.gui.idle")
local hold_serial, hold_down, hold_release = 0, false, nil
local hold_start, hold_path, idle_since = 0, "", nil
local guard_previous = {}
log_provider=function()
    return "hold=" .. hold_state .. " serial=" .. hold_serial .. " down=" .. tostring(hold_down) ..
        " start=" .. hold_start .. " release=" .. tostring(hold_release) ..
        " idle_since=" .. tostring(idle_since) .. " opened=" .. tostring(opened) ..
        " picker_worker=" .. tostring(worker_running) .. " hold_worker=" .. tostring(hold_worker_running) ..
        " busy=" .. tostring(busy) .. " committed=" .. tostring(committed)
end
-- One read per guard per invocation; transitions only in the poll path.
local function hold_guard(where, now)
    local path=fetch("dryos.config_dir.path")
    local fields={
        {"movie.recording",fetch("movie.recording"),false},
        {"busy",busy,false}, {"opened",opened,false},
        {"worker_running",worker_running,false}, {"committed",committed,false},
        {"runtime-path",path,hold_down and hold_path or path},
        {"lv.running",fetch("lv.running"),true},
        {"menu.visible",fetch("menu.visible"),false},
        {"camera.gui.idle",fetch("camera.gui.idle"),true},
    }
    local failed
    for _, f in ipairs(fields) do
        local name,v,expected=f[1],f[2],f[3]
        local repr=value(v)
        if guard_previous[name]~=repr then
            guard_previous[name]=repr
            journal("GUARD_CHANGE", "phase=" .. where .. " guard=" .. name .. " value=" .. repr, false, now)
        end
        local invalid=v~=expected
        if name=="runtime-path" then
            invalid=type(v)~="string" or not v:match("/SETTINGS/[^/]+/?$") or v~=expected
        elseif name=="camera.gui.idle" and hold_down and type(v)=="boolean" then
            -- Even a recovery sample at exactly 300ms is too late.
            if idle_since and now-idle_since>=300 then
                invalid=true
                repr=repr .. " idle-loss duration=" .. (now-idle_since) .. "ms"
            elseif not v then
                idle_since=idle_since or now;invalid=false
            else idle_since=nil;invalid=false end
        end
        if invalid and not failed then failed=name .. "=" .. repr end
    end
    return failed
end
local function cancel_hold(reason, where, at)
    if reason then rejected("candidate=" .. hold_serial .. " " .. reason,where,at) end
    hold_down, hold_release, idle_since = false, nil, nil
    hold_serial=hold_serial+1
end
local function hold_key(k, now)
    now=now or dryos.ms_clock
    local where=k==KEY.UNPRESS_UDLR and "release" or "during-hold key"
    if hold_down then
        if type(now)~="number" or now<hold_start then
            cancel_hold("clock-backward value=" .. tostring(now),where,now);return
        end
        local why=hold_guard(where,now)
        if why then cancel_hold(why,where,now);return end
    end
    if k==KEY.JOY_CENTER and not hold_down then
        local why=hold_guard("arm",now)
        if not why and hold_worker_running then why="hold_worker_running=true" end
        if why then rejected(why,"arm",now);return end
        hold_down, hold_release, idle_since=true,nil,nil
        hold_serial=hold_serial+1
        hold_start,hold_path=now,dryos.config_dir.path
        hold_state="armed"
        local mine=hold_serial
        -- v3.4.4: one action on every preset, PHOTO_FILM included.
        journal("ARM", "candidate=" .. mine .. " action=open-picker", false, now)
        -- v3.4.8: disable the ML core's 500ms joystick long-press action.
        -- The existing WOBBLE branch keeps our hold candidate alive.
        if HOLD_WOBBLE_KEY then
            local okp, perr = pcall(key.press, HOLD_WOBBLE_KEY)
            journal("WOBBLE_SYNTH", "key=" .. tostring(HOLD_WOBBLE_KEY) .. " ok=" .. tostring(okp) .. (perr and (" err=" .. tostring(perr)) or ""), false, now)
        end
        hold_worker_running=true
        local ok, create_err=pcall(task.create,function()
            journal("HOLD_WORKER_START", "candidate=" .. mine)
            local accepted=false
            local worked,err=pcall(function()
                while hold_serial==mine and hold_down do
                    local at=dryos.ms_clock
                    local elapsed=at-hold_start
                    local poll_phase=hold_release and "release" or "during-hold poll"
                    if elapsed<0 then cancel_hold("clock-backward elapsed=" .. elapsed,poll_phase,at);break end
                    -- Physical release wins over worker scheduling delay.
                    local duration=hold_release and hold_release-hold_start or elapsed
                    if duration>10000 then cancel_hold("timeout duration=" .. duration,poll_phase,at);break end
                    local why=hold_guard(poll_phase,at)
                    if why then cancel_hold(why,poll_phase,at);break end
                    if hold_release then
                        if duration<1200 then cancel_hold("too-short duration=" .. duration,"release",hold_release)
                        else accepted=true end
                        break
                    end
                    task.yield(50)
                end
            end)
            if not worked then
                if hold_serial==mine then cancel_hold("worker-error=" .. value(err),"during-hold poll") end
                fault("joystick hold",err)
            end
            if hold_serial==mine then cancel_hold() else accepted=false end
            hold_worker_running=false -- finish before picker task can yield
            journal("HOLD_WORKER_END", "candidate=" .. mine .. " serial=" .. hold_serial .. " accepted=" .. tostring(accepted))
            if accepted then
                hold_state="released"
                -- v3.4.4: the hold opens the ordinary picker (no apply, no reboot);
                -- Film Roll direct entry is video TRASH only (trash_film below).
                journal("HOLD_PICKER","candidate=" .. mine .. " action=open-picker path=" .. hold_path)
                open_picker(false,mine)
            end
        end)
        journal("HOLD_TASK_CREATE", "ok=" .. tostring(ok) .. " error=" .. tostring(create_err))
        if not ok then
            hold_worker_running=false
            cancel_hold("task.create=" .. value(create_err),"arm",now)
            fault("hold task.create",create_err)
        end
    elseif k==KEY.UNPRESS_UDLR and hold_down then
        hold_release=hold_release or now
        hold_state="release-pending"
        journal("RELEASE", "candidate=" .. hold_serial .. " duration=" .. (hold_release-hold_start), false, now)
    elseif hold_down and (k==KEY.UP or k==KEY.DOWN or k==KEY.LEFT or k==KEY.RIGHT or
        k==fetch("KEY.UP_RIGHT") or k==fetch("KEY.UP_LEFT") or
        k==fetch("KEY.DOWN_RIGHT") or k==fetch("KEY.DOWN_LEFT")) then
        journal("WOBBLE", "key=" .. k .. " continue=true", false, now)
    elseif hold_down and k~=KEY.JOY_CENTER then
        local reason=(k>=1 and k<=4) and "shutter-key value=" or "other-key value="
        cancel_hold(reason .. k, "during-hold key", now)
    end
end

-- v3.4.2: video TRASH enters Film Roll through the joystick hold's guards,
-- candidate bookkeeping and apply flow; only the trigger differs. No I/O here.
local function trash_film(now)
    local why=hold_guard("trash",now)
    if not why and (hold_down or hold_worker_running) then why="hold_worker_running=true" end
    if why then rejected(why,"trash",now); return false end
    hold_serial=hold_serial+1
    local mine=hold_serial
    hold_state="trash"
    journal("TRASH_FILM", "candidate=" .. mine .. " action=enter-film", false, now)
    return open_picker(true,mine)
end

dispatch = function(k, at)
    -- v3.4.4: while the picker owns the screen the joystick centre is its close
    -- key, not a hold candidate; every other key still reaches the hold tracker.
    if not (opened and k==KEY.JOY_CENTER and not hold_down) then
        hold_key(k, at) -- no filesystem I/O, sleep or shutter interception; key synthesis only at ARM (HOLD_WOBBLE_KEY)
    end
    if opened then
        -- Let capture controls through; dismiss before returning them to ML.
        if k==KEY.HALFSHUTTER or k==KEY.FULLSHUTTER or k==KEY.REC or k==KEY.LV or k==KEY.PLAY then
            if not busy then close_picker(false) end
            return not busy
        end
        if k==KEY.TRASH or k==KEY.Q or k==KEY.MENU or k==KEY.SET or k==KEY.JOY_CENTER or
           k==KEY.UP or k==KEY.DOWN or k==KEY.LEFT or k==KEY.RIGHT or
           k==KEY.WHEEL_UP or k==KEY.WHEEL_DOWN or k==KEY.WHEEL_LEFT or k==KEY.WHEEL_RIGHT then
            if not busy and #queue<16 then queue[#queue+1]=k end
            return false
        end
        return true -- releases / unrelated events remain available
    end
    -- Only idle LiveView: do not steal Canon playback's delete command.
    -- If this core consumes TRASH earlier, use the registered menu action below.
    local photo=dryos.config_dir.path:match("/PHOTO_FILM/?$")~=nil
    if lv.running and camera.gui.idle and not movie.recording and not menu.visible then
        -- filmroll.mo owns TRASH upstream in PHOTO_FILM; a TRASH that still reaches
        -- Lua there keeps opening the picker. v3.4.4: Q is released on every preset
        -- (Canon/ML/filmroll keep it); the picker opens only from the joystick hold
        -- (hold_key above) or this TRASH route. Video TRASH enters Film Roll directly.
        -- A refused request is passed on as before.
        if TRASH_SHORTCUT and k==KEY.TRASH and not photo then
            if trash_film(at) then return false end
        elseif TRASH_SHORTCUT and k==KEY.TRASH then
            if open_picker() then return false end
        end
    end
    return true
end


    request_open = open_picker
end
local ok, err = pcall(initialise)
if ok then phase="armed" else phase="feature-error"; fault("initialise", err) end
journal("INIT_END", "result=" .. phase .. " error=" .. value(last_error))
flush_journal() -- v3.4.3: persist BOOT/INIT before any later evidence read
pcall(function()
    local f=io.open("ML/SETTINGS/CURRENT.SET","rb")
    if f then
        local ok,data=pcall(f.read,f,129);f:close()
        journal("BOOT_FILE", "CURRENT.SET=" .. (ok and value(data) or "read-error"))
    end
end)
-- Last saved Film Roll state: bounded read once at boot, shared by evidence and apply guard.
pcall(function()
    local f=io.open("ML/SETTINGS/PHOTO_FILM/filmroll.cfg","rb")
    if f then
        local ok,data=pcall(f.read,f,1024); f:close()
        film_loaded = ok and type(data)=="string" and
            data:match("film%.loaded%s*=%s*([+-]?%d+)") or "unknown"
        journal("FILM_EVIDENCE", "film.loaded=" .. film_loaded)
    else journal("FILM_EVIDENCE", "film.loaded=unknown") end
end)
flush_journal()
diagnostic("[picker v3] " .. phase .. "; active=" .. active_path() .. "; TRASH=25")
-- No top-level sleep/loop/task: diagnostic callbacks retain this Lua state.
