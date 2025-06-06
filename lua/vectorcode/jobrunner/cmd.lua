---@type VectorCode.JobRunner
local runner = {}

local Job = require("plenary.job")
---@type {integer: Job}
local jobs = {}
local logger = require("vectorcode.config").logger

function runner.run_async(args, callback, bufnr)
  if type(callback) == "function" then
    callback = vim.schedule_wrap(callback)
  else
    callback = nil
  end
  logger.debug(
    ("cmd jobrunner for buffer %s args: %s"):format(bufnr, vim.inspect(args))
  )
  ---@diagnostic disable-next-line: missing-fields
  local job = Job:new({
    command = require("vectorcode.config").get_user_config().cli_cmds.vectorcode,
    args = args,
    on_exit = function(self, code, signal)
      jobs[self.pid] = nil
      local result = self:result()
      logger.debug(result)
      local ok, decoded = pcall(vim.json.decode, table.concat(result, ""))
      if callback ~= nil then
        if ok then
          callback(decoded or {}, self:stderr_result(), code, signal)
          if vim.islist(result) then
            logger.debug(
              "cmd jobrunner result:\n",
              vim.tbl_map(function(item)
                if type(item) == "table" then
                  item.document = nil
                  item.chunk = nil
                end
                return item
              end, vim.deepcopy(result))
            )
          end
        else
          callback({ result }, self:stderr_result(), code, signal)
          logger.warn("cmd runner: failed to decode result:\n", result)
        end
      end
    end,
  })
  local ok = pcall(job.start, job)
  if ok then
    jobs[job.pid] = job
    return tonumber(job.pid)
  else
    logger.error("Failed to start job.")
  end
end

function runner.run(args, timeout_ms, bufnr)
  if timeout_ms == nil or timeout_ms < 0 then
    timeout_ms = 2 ^ 31 - 1
  end
  local res, err, code, signal
  local pid = runner.run_async(args, function(result, error, e_code, s)
    res = result
    err = error
    code = e_code
    signal = s
  end, bufnr)
  if pid ~= nil then
    vim.wait(timeout_ms, function()
      return res ~= nil or err ~= nil
    end)
    jobs[pid] = nil
  end
  return res or {}, err, code, signal
end

function runner.is_job_running(job)
  return jobs[job] ~= nil
end

function runner.stop_job(job_handle)
  local job = jobs[job_handle]
  if job ~= nil then
    job:shutdown(1, 15)
  end
end

return runner
