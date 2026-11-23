-- REC frame v3.3
-- Keep the known-working direct 6 px rectangles, pin before spawning.
-- Autorun remains the existing RECFRAME.LEN in the runtime config folder.
print("[recframe v3.3] LOAD")
local phase, last_error, frames, starts = "bootstrap", "", 0, 0
local status_menu
local function status()
    print("[recframe v3.3] phase=" .. phase .. " starts=" .. starts ..
        " frames=" .. frames .. " error=" .. last_error)
end
local ok, err = pcall(function()
    -- REAL module: menu.new synchronously sets cant_unload at .text+0x23518.
    -- task.create alone does not. Do not remove/move this before task.create.
    status_menu = assert(menu.new {
        parent="Scripts", name="REC frame status",
        help="v3.3 phase, worker starts and REC redraw count. SET prints to console.",
        select=status,
    })
    assert(type(task.create)=="function" and type(task.yield)=="function", "missing task API")
    assert(type(display.rect)=="function" and type(COLOR.RED)=="number", "missing drawing API")
    assert(type(movie.recording)=="boolean", "missing recording state")
    phase="scheduled"
    task.create(function()
        starts=starts+1
        phase="running"
        print("[recframe v3.3] WORKER start=" .. starts)
        local ran, why = pcall(function()
            local W, H, T = 720, 480, 6
            while true do
                if movie.recording then
                    display.rect(0, 0, W, T, COLOR.RED, COLOR.RED)
                    display.rect(0, H-T, W, T, COLOR.RED, COLOR.RED)
                    display.rect(0, 0, T, H, COLOR.RED, COLOR.RED)
                    display.rect(W-T, 0, T, H, COLOR.RED, COLOR.RED)
                    frames=frames+1
                end
                -- Only this worker yields; status callback never yields.
                task.yield(150)
            end
        end)
        phase="worker-stopped"
        if not ran then last_error=tostring(why) end
        status()
    end)
end)
if not ok then phase="load-error"; last_error=tostring(err) end
status()
-- Return to serial autoload. Status menu retains the state before worker starts.
