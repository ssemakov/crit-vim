-- Thin HTTP client over `curl`, called async via vim.system. All requests
-- return via callback: cb(ok, decoded_body, http_status). Errors are logged
-- via vim.notify and cb is called with ok=false.

local M = {}

local function decode_body(body)
  if body == nil or body == "" then return nil end
  local ok, decoded = pcall(vim.json.decode, body)
  if ok then return decoded end
  return body
end

-- args: { method, url, body (optional table -> json), on_done (cb) }
-- cb signature: (ok:boolean, decoded_body:any, http_status:integer|nil)
function M.request(args)
  local method = args.method or "GET"
  local url = args.url
  local cmd = {
    "curl", "-sS",
    "-X", method,
    "-w", "\n__HTTP_STATUS__:%{http_code}",
    "--max-time", tostring(args.timeout or 30),
  }
  local stdin = nil
  if args.body ~= nil then
    table.insert(cmd, "-H")
    table.insert(cmd, "Content-Type: application/json")
    table.insert(cmd, "-d")
    if type(args.body) == "string" then
      table.insert(cmd, args.body)
    else
      table.insert(cmd, vim.json.encode(args.body))
    end
  end
  table.insert(cmd, url)

  vim.system(cmd, { text = true, stdin = stdin }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        args.on_done(false, obj.stderr or ("curl failed: exit " .. obj.code), nil)
        return
      end
      local out = obj.stdout or ""
      local body, status = out, nil
      local anchor = out:find("\n__HTTP_STATUS__:", 1, true)
      if anchor then
        body = out:sub(1, anchor - 1)
        status = tonumber(out:sub(anchor + #"\n__HTTP_STATUS__:"))
      end
      local decoded = decode_body(body)
      if status and status >= 400 then
        args.on_done(false, decoded, status)
      else
        args.on_done(true, decoded, status)
      end
    end)
  end)
end

-- Convenience wrappers. All take a base_url (e.g. "http://127.0.0.1:49609").
function M.get(base_url, path, cb) M.request({ method = "GET", url = base_url .. path, on_done = cb }) end
function M.post(base_url, path, body, cb) M.request({ method = "POST", url = base_url .. path, body = body, on_done = cb }) end
function M.put(base_url, path, body, cb) M.request({ method = "PUT", url = base_url .. path, body = body, on_done = cb }) end
function M.delete(base_url, path, cb) M.request({ method = "DELETE", url = base_url .. path, on_done = cb }) end

-- URL-encode a single path segment.
function M.url_encode(s)
  return (s:gsub("[^%w%-_.~/]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

return M
