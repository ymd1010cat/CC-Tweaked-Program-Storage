-- jobs.lua - background jobs and job control for ush
--
-- Honest semantics: CraftOS is single threaded and a Lua coroutine can only be
-- suspended where the running code yields. ush therefore implements
-- cooperative background jobs:
--
--   * "cmd &" creates a coroutine and returns to the prompt immediately;
--   * the coroutine is advanced from the shell idle hook (the line editor
--     timer, and the scheduler hook that startup.lua drives while ush is not
--     running);
--   * a job that never yields (a pure CPU loop, or a command that only calls
--     blocking CraftOS functions) runs to completion in one slice, exactly
--     like a foreground command;
--   * there is no preemption, no job specific terminal and no memory
--     isolation: all jobs share the shell globals.
--
-- kill() asks the blocked job to stop by firing a "terminate" event, which is
-- how CraftOS interrupts a program waiting in os.pullEvent/os.sleep; a job
-- that is not waiting on an event can only be marked as killed.
local jobs = {}

local table_jobs = {}
local next_id = 1
local runner = nil
local MAX_JOBS = 32
local SLICE_BUDGET = 8     -- resumes per shell prompt, keeps the shell usable

local function now()
    local ok, e = pcall(os.epoch, "utc")
    if ok and type(e) == "number" then return math.floor(e / 1000) end
    return os.time()
end

function jobs.set_runner(fn)
    runner = fn
end

function jobs.runner()
    return runner
end

function jobs.list()
    local out = {}
    for _, j in ipairs(table_jobs) do out[#out + 1] = j end
    return out
end

function jobs.get(id)
    for _, j in ipairs(table_jobs) do
        if j.id == id then return j end
    end
    return nil
end

-- Resolve "%1", "1" or "%%" into a job id.
function jobs.resolve(spec)
    if type(spec) == "number" then return spec end
    if type(spec) ~= "string" or spec == "" then return nil end
    local s = spec:gsub("^%%", "")
    return tonumber(s)
end

function jobs.active_count()
    local n = 0
    for _, j in ipairs(table_jobs) do
        if j.state == "running" or j.state == "stopped" then n = n + 1 end
    end
    return n
end

local function reap()
    local kept = {}
    for _, j in ipairs(table_jobs) do
        -- Finished jobs stay visible for a few entries so that "jobs" can
        -- still report them, but the table may not grow without bound.
        if j.state == "done" or j.state == "killed" then
            j.reaped = (j.reaped or 0) + 1
            if j.reaped <= 2 then kept[#kept + 1] = j end
        else
            kept[#kept + 1] = j
        end
    end
    table_jobs = kept
end

function jobs.spawn(command)
    if not runner then return nil, "no job runner registered" end
    if jobs.active_count() >= MAX_JOBS then
        return nil, "too many background jobs (limit " .. MAX_JOBS .. ")"
    end

    local job = {
        id = next_id,
        command = command,
        state = "running",
        status = nil,
        started = now(),
        yields = 0,
        killed = false,
    }
    next_id = next_id + 1

    job.co = coroutine.create(function()
        local ok, err = pcall(runner, command)
        if not ok then
            print("ush: job " .. job.id .. ": " .. tostring(err))
            return 1
        end
        return tonumber(err) or 0
    end)

    table_jobs[#table_jobs + 1] = job
    reap()
    return job
end

-- Advance every runnable job by at most one coroutine resume. A resume that
-- returns without yielding means the job is finished.
function jobs.pump(budget)
    budget = budget or SLICE_BUDGET
    local advanced = 0
    for _, j in ipairs(table_jobs) do
        if j.state == "running" and advanced < budget then
            advanced = advanced + 1
            jobs.step(j)
        end
    end
    reap()
    return advanced
end

-- Advance a single job one slice. Returns true while the job is still alive.
function jobs.step(job)
    if not job.co or job.state == "done" or job.state == "killed" then
        return false
    end
    if coroutine.status(job.co) == "dead" then
        job.state = "done"
        return false
    end

    local ok, res = coroutine.resume(job.co)
    job.yields = job.yields + 1

    if not ok then
        job.state = "done"
        job.status = 1
        print("ush: job " .. job.id .. ": " .. tostring(res))
        return false
    end

    if coroutine.status(job.co) == "dead" then
        job.state = job.killed and "killed" or "done"
        job.status = tonumber(res) or 0
        return false
    end

    job.state = "running"
    return true
end

-- fg: run the job until it finishes or until it yields `slices` times, so a
-- service style job does not lock the shell forever.
function jobs.foreground(id, slices)
    local job = jobs.get(id)
    if not job then return nil, "no such job" end
    slices = slices or 200
    local n = 0
    while job.state == "running" and n < slices do
        jobs.step(job)
        n = n + 1
        if coroutine.status(job.co) == "dead" then break end
    end
    return job
end

function jobs.background(id)
    local job = jobs.get(id)
    if not job then return nil, "no such job" end
    if job.state == "done" then return nil, "job already finished" end
    if job.state == "killed" then
        return nil, "job was killed and cannot be restarted"
    end
    job.state = "running"
    return job
end

-- Stop a job. The "terminate" event is the CraftOS mechanism for interrupting
-- a program blocked in os.pullEvent/os.sleep; a job that is between yields is
-- merely flagged and will not be scheduled again.
function jobs.kill(id)
    local job = jobs.get(id)
    if not job then return nil, "no such job" end
    if job.state == "done" then return nil, "job already finished" end
    job.killed = true
    os.queueEvent("terminate")
    jobs.step(job)
    if coroutine.status(job.co) ~= "dead" then
        job.state = "killed"
    end
    return job
end

function jobs.clean()
    local kept = {}
    for _, j in ipairs(table_jobs) do
        if j.state == "running" or j.state == "stopped" then
            kept[#kept + 1] = j
        end
    end
    table_jobs = kept
    reap()
    return true
end

function jobs.reset()
    table_jobs = {}
    next_id = 1
    return true
end

return jobs
