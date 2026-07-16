-- SSE (server-sent events) subscription over `curl --no-buffer`.
-- Parses `event: X\ndata: {...}\n\n` blocks and calls on_event(type, data_decoded).
--
-- Returns { stop = fn } — call stop() to kill the curl subprocess.

local M = {}

-- opts: { base_url, on_event (fn(type, data)), on_close (fn()), on_error (fn(err)) }
function M.subscribe(opts)
  local url = opts.base_url .. "/api/events"
  local cmd = { "curl", "-sS", "-N", "--no-buffer", url }

  local buf = ""
  local event_type = nil

  local function flush_block(block)
    -- A block is one or more lines terminated by a blank line.
    for line in (block .. "\n"):gmatch("([^\n]*)\n") do
      if line:sub(1, 1) == ":" then
        -- comment / heartbeat, ignore
      elseif line:sub(1, 7) == "event: " then
        event_type = line:sub(8)
      elseif line:sub(1, 6) == "data: " then
        local raw = line:sub(7)
        local ok, decoded = pcall(vim.json.decode, raw)
        local data = ok and decoded or raw
        if opts.on_event then
          pcall(opts.on_event, event_type or "message", data)
        end
      end
    end
    event_type = nil
  end

  local sys = vim.system(cmd, {
    text = true,
    stdout = function(err, chunk)
      if err then return end
      if not chunk then return end
      vim.schedule(function()
        buf = buf .. chunk
        -- Split on double newline (block terminator).
        while true do
          local sep = buf:find("\n\n", 1, true)
          if not sep then break end
          local block = buf:sub(1, sep - 1)
          buf = buf:sub(sep + 2)
          flush_block(block)
        end
      end)
    end,
    stderr = function(err, chunk)
      if err or not chunk then return end
      vim.schedule(function()
        if opts.on_error then pcall(opts.on_error, chunk) end
      end)
    end,
  }, function(obj)
    vim.schedule(function()
      if opts.on_close then pcall(opts.on_close, obj) end
    end)
  end)

  return {
    stop = function()
      pcall(function() sys:kill(15) end)
    end,
  }
end

return M
