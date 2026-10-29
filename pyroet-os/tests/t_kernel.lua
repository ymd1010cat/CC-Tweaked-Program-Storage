--[[- pyroet-os/tests/t_kernel.lua -- service manager: order, isolation, health.

No non-ASCII bytes in this file.
]]

local kernel = dofile("/system/kernel/init.lua")

return function(H)
    local function entry(status, name)
        for i = 1, #status.services do
            if status.services[i].name == name then return status.services[i] end
        end
        return nil
    end

    local function up()
        return true
    end

    -- -----------------------------------------------------------------
    H.group("kernel.order")
    do
        local log, lines = H.logger()
        local k = kernel.new({ log = log })
        local seen = {}
        local function svc(label, deps)
            return {
                deps = deps or {},
                start = function() seen[#seen + 1] = label; return true end,
            }
        end

        local record = k:register("ui", svc("ui", { "net" }))
        k:register("net", svc("net"))
        k:register("input", svc("input", { "net" }))

        H.table("register_returns_record", record)
        H.eq("record_name", record and record.name, "ui")
        H.has(lines, "KERNEL_REGISTER name=ui deps=net")
        H.has(lines, "KERNEL_REGISTER name=net deps=-")

        local status = k:start_all()
        H.eq("start_order", table.concat(seen, ","), "net,ui,input")
        H.eq("registered", status.counts.registered, 0)
        H.eq("running", status.counts.running, 3)
        H.eq("failed", status.counts.failed, 0)
        H.eq("skipped", status.counts.skipped, 0)
        H.eq("health", status.health, "ok")
        H.check("not_fatal", status.fatal == false, "fatal=" .. tostring(status.fatal))
        H.has(lines, "KERNEL_SERVICE_START name=net")
        H.has(lines, "KERNEL_READY services=3")
        H.eq("names", table.concat(k:names(), ","), "ui,net,input")
        H.eq("get_state", k:get("net") and k:get("net").state, "running")
        H.eq("get_unknown", k:get("nope"), nil)
        H.eq("status_started", status.started, true)
        local ui = entry(status, "ui")
        H.table("status_entry", ui)
        H.eq("entry_deps", ui and #ui.deps, 1)
        H.eq("entry_dep_name", ui and ui.deps[1], "net")
        H.eq("entry_healthy", ui and ui.healthy, "ok")
    end

    -- -----------------------------------------------------------------
    H.group("kernel.failure")
    do
        local log, lines = H.logger()
        local k = kernel.new({ log = log })
        local child_started = false
        local got_self = nil

        k:register("good", { start = function(self) got_self = self; return true end })
        k:register("bad", { start = function() error("boom") end })
        k:register("child", { deps = { "bad" }, start = function()
            child_started = true
            return true
        end })
        k:register("grand", { deps = { "child" }, start = up })
        k:register("other", { start = up })
        k:register("falsey", { start = function() return false, "nope" end })
        k:register("nilly", { start = function() end })

        local status = k:start_all()
        H.eq("good_running", entry(status, "good").state, "running")
        H.eq("bad_failed", entry(status, "bad").state, "failed")
        H.eq("child_skipped", entry(status, "child").state, "skipped")
        H.eq("grand_skipped", entry(status, "grand").state, "skipped")
        H.eq("other_running", entry(status, "other").state, "running")
        H.eq("falsey_failed", entry(status, "falsey").state, "failed")
        H.eq("nilly_failed", entry(status, "nilly").state, "failed")
        H.check("child_never_started", child_started == false,
            "a skipped service must not run")
        H.check("start_receives_kernel", got_self == k, "start(self) was not the kernel")
        H.eq("health_degraded", status.health, "degraded")
        H.check("not_fatal", status.fatal == false, "fatal=" .. tostring(status.fatal))
        H.eq("running_count", status.counts.running, 2)
        H.eq("failed_count", status.counts.failed, 3)
        H.eq("skipped_count", status.counts.skipped, 2)
        H.has(lines, "KERNEL_SERVICE_FAIL name=bad err=")
        H.contains("fail_keeps_error", H.joined(lines), "boom")
        H.has(lines, "KERNEL_SERVICE_SKIP name=child missing=bad")
        H.has(lines, "KERNEL_SERVICE_SKIP name=grand missing=child")
        H.has(lines, "KERNEL_SERVICE_FAIL name=falsey err=nope")
        H.has(lines, "KERNEL_SERVICE_FAIL name=nilly err=start returned no value")
        H.has(lines, "KERNEL_DEGRADED health=degraded")
        H.lacks("no_ready_line", lines, "KERNEL_READY")
    end

    -- -----------------------------------------------------------------
    H.group("kernel.deps")
    do
        -- cycle
        local log, lines = H.logger()
        local k = kernel.new({ log = log })
        local ran = {}
        k:register("a", { deps = { "b" }, start = function() ran[#ran + 1] = "a"; return true end })
        k:register("b", { deps = { "a" }, start = function() ran[#ran + 1] = "b"; return true end })
        local status = k:start_all()
        H.eq("cycle_a", entry(status, "a").state, "failed")
        H.eq("cycle_b", entry(status, "b").state, "failed")
        H.eq("cycle_a_error", entry(status, "a").error, "dependency cycle")
        H.eq("cycle_ran_nothing", #ran, 0)
        H.has(lines, "KERNEL_DEP_CYCLE")
        H.eq("cycle_health", status.health, "failed")
        H.check("cycle_fatal", status.fatal == true, "a dead kernel must be fatal")

        -- unknown dependency
        local log2, lines2 = H.logger()
        local k2 = kernel.new({ log = log2 })
        k2:register("x", { deps = { "ghost" }, start = up })
        local status2 = k2:start_all()
        H.eq("unknown_state", entry(status2, "x").state, "failed")
        H.has(lines2, "KERNEL_UNKNOWN_DEP name=x dep=ghost")
        H.contains("unknown_error", entry(status2, "x").error or "", "unknown dependency")
        H.eq("unknown_health", status2.health, "failed")

        -- self dependency is rejected at registration
        local k3 = kernel.new({})
        local ok, err = k3:register("loop", { deps = { "loop" }, start = up })
        H.check("self_dep_rejected", ok == nil, "ok=" .. tostring(ok))
        H.contains("self_dep_error", err, "cannot depend on itself")
    end

    -- -----------------------------------------------------------------
    H.group("kernel.health")
    do
        local log, lines = H.logger()
        local k = kernel.new({ log = log })
        k:register("h_ok", { start = up, health = function() return true end })
        k:register("h_nil", { start = up, health = function() end })
        k:register("h_deg", { start = up, health = function() return "degraded" end })
        k:register("h_throw", { start = up, health = function() error("nope") end })
        k:register("h_false", { start = up, health = function() return false end })
        k:register("h_weird", { start = up, health = function() return "strange" end })

        local status = k:start_all()
        H.eq("h_ok", entry(status, "h_ok").healthy, "ok")
        H.eq("h_nil", entry(status, "h_nil").healthy, "ok")
        H.eq("h_deg", entry(status, "h_deg").healthy, "degraded")
        H.eq("h_throw", entry(status, "h_throw").healthy, "failed")
        H.eq("h_false", entry(status, "h_false").healthy, "failed")
        H.eq("h_weird", entry(status, "h_weird").healthy, "degraded")
        H.eq("aggregate", status.health, "degraded")
        H.check("hook_cannot_fatal", status.fatal == false, "a health hook killed the kernel")
        H.has(lines, "KERNEL_SERVICE_HEALTH_FAIL name=h_false err=reported_failed")
        H.has(lines, "KERNEL_SERVICE_HEALTH_UNKNOWN name=h_weird value=strange")
        H.contains("health_error_text", H.joined(lines), "nope")

        -- all healthy is the only way to "ok"
        local k2 = kernel.new({})
        k2:register("only", { start = up, health = function() return true end })
        H.eq("ok_health", k2:start_all().health, "ok")
    end

    -- -----------------------------------------------------------------
    H.group("kernel.stop")
    do
        local log, lines = H.logger()
        local k = kernel.new({ log = log })
        local order = {}
        local function svc(label, deps)
            return {
                deps = deps or {},
                start = up,
                stop = function() order[#order + 1] = label end,
            }
        end
        k:register("a", svc("a"))
        k:register("b", svc("b", { "a" }))
        k:register("c", svc("c", { "b" }))
        k:start_all()

        H.eq("stopped_count", k:stop_all(), 3)
        H.eq("stop_reverse_order", table.concat(order, ","), "c,b,a")
        H.eq("state_a", k:get("a").state, "stopped")
        H.has(lines, "KERNEL_SERVICE_STOP name=c")
        H.has(lines, "KERNEL_STOPPED services=3")
        H.eq("stop_again", k:stop_all(), 0)
        H.has(lines, "KERNEL_STOPPED services=0")

        local status = k:status()
        H.eq("stopped_flag", status.stopped, true)
        H.eq("stopped_running", status.counts.running, 0)
        H.eq("stopped_health", status.health, "ok")

        -- a stop that raises is reported and does not abort the rest
        local log2, lines2 = H.logger()
        local k2 = kernel.new({ log = log2 })
        local later = false
        k2:register("first", { start = up, stop = function() error("stuck") end })
        k2:register("second", { start = up, stop = function() later = true end })
        k2:start_all()
        H.eq("stop_all_called", k2:stop_all(), 2)
        H.check("later_stop_ran", later == true, "a failing stop skipped the next one")
        H.has(lines2, "KERNEL_SERVICE_STOP_FAIL name=first err=")
        H.eq("failing_stop_state", k2:get("first").state, "stopped")
    end

    -- -----------------------------------------------------------------
    H.group("kernel.api")
    do
        local k = kernel.new({})
        H.eq("bad_name", select(1, k:register("bad name", { start = up })), nil)
        H.eq("bad_spec", select(1, k:register("x", "nope")), nil)
        H.contains("no_start_error", select(2, k:register("y", {})),
            "start must be a function")
        H.contains("start_type_error", select(2, k:register("z", { start = 1 })),
            "start must be a function")
        k:register("ok1", { start = up })
        local dup, dup_err = k:register("ok1", { start = up })
        H.check("duplicate_rejected", dup == nil, "ok=" .. tostring(dup))
        H.contains("duplicate_error", dup_err, "duplicate service")
        H.contains("stop_type_error",
            select(2, k:register("s1", { start = up, stop = 1 })),
            "stop must be a function")
        H.contains("health_type_error",
            select(2, k:register("s2", { start = up, health = 1 })),
            "health must be a function")
        H.contains("deps_type_error",
            select(2, k:register("s3", { start = up, deps = "net" })),
            "deps must be a list")
        H.contains("dep_name_error",
            select(2, k:register("s4", { start = up, deps = { 1 } })),
            "dep must be a name")

        local log, lines = H.logger()
        local k2 = kernel.new({ log = log })
        k2:register("one", { start = up })
        local first = k2:start_all()
        local second = k2:start_all()
        H.has(lines, "KERNEL_ALREADY_STARTED services=1")
        H.eq("double_start_health", second.health, first.health)
        H.check("late_register_rejected",
            k2:register("late", { start = up }) == nil, "register after start was accepted")
    end

    -- -----------------------------------------------------------------
    H.group("kernel.empty")
    do
        local log, lines = H.logger()
        local k = kernel.new({ log = log })
        local status = k:start_all()
        H.eq("empty_health", status.health, "ok")
        H.check("empty_not_fatal", status.fatal == false, "empty kernel was fatal")
        H.eq("empty_registered", status.counts.registered, 0)
        H.has(lines, "KERNEL_READY services=0")
    end

    -- -----------------------------------------------------------------
    H.group("kernel.logs")
    do
        local log, lines = H.logger()
        local k = kernel.new({ log = log })
        k:register("a", { start = up })
        k:start_all()
        H.eq("ring_matches_sink", #k:lines(), #lines)
        H.ascii_check("logs_ascii", k:text())
        H.eq("text_joined", k:text(), table.concat(lines, "\n"))
    end
end
