-- lua-highlight-check.lua
-- 用途：验证 DSH 是否已内置 Lua 语法高亮；验证后可直接删除本文件。
-- DSH 前端自带 Shiki 的 Lua 语法块：@deepseek-ai/dsh-web-frontend/dist/assets/langs/lua-*.js

local M = {}

--- 计算斐波那契数列
-- @param n number
-- @return number
function M.fib(n)
  if n < 2 then
    return n
  end
  return M.fib(n - 1) + M.fib(n - 2)
end

local fruits = { "apple", "banana", "cherry" }
for i, name in ipairs(fruits) do
  print(string.format("%d: %s (len=%d)", i, name, #name))
end

local config = {
  name = "dsh",
  version = "0.1.7",
  features = { "shiki", "lua", "codemirror" },
  enabled = true,
}

local function greet(who)
  return ("hello, %s!"):format(who or "world")
end

print(greet(config.name), M.fib(10))

return M
