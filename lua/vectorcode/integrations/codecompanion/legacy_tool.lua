---@module "codecompanion"

local cc_common = require("vectorcode.integrations.codecompanion.common")
local vc_config = require("vectorcode.config")
local check_cli_wrap = vc_config.check_cli_wrap

local logger = vc_config.logger

local job_runner = nil

---@param opts VectorCode.CodeCompanion.ToolOpts?
---@return CodeCompanion.Agent.Tool
return check_cli_wrap(function(opts)
  if opts == nil or opts.use_lsp == nil then
    opts = vim.tbl_deep_extend(
      "force",
      opts or {},
      { use_lsp = vc_config.get_user_config().async_backend == "lsp" }
    )
  end
  opts = vim.tbl_deep_extend("force", {
    max_num = -1,
    default_num = 10,
    include_stderr = false,
    use_lsp = false,
    auto_submit = { ls = false, query = false },
    ls_on_start = false,
    no_duplicate = true,
  }, opts or {})
  logger.info("Creating CodeCompanion tool with the following args:\n", opts)
  local capping_message = ""
  if opts.max_num > 0 then
    capping_message = ("  - Request for at most %d documents"):format(opts.max_num)
  end

  return {
    name = "vectorcode",
    cmds = {
      ---@param agent CodeCompanion.Agent
      ---@param action table
      ---@param input table
      ---@return nil|{ status: string, msg: string }
      function(agent, action, input, cb)
        logger.info("CodeCompanion tool called with the following arguments:\n", action)
        job_runner = cc_common.initialise_runner(opts.use_lsp)
        assert(job_runner ~= nil)
        assert(
          type(cb) == "function",
          "Please upgrade CodeCompanion.nvim to at least 13.5.0"
        )
        assert(vim.list_contains({ "ls", "query" }, action.command))
        if opts.auto_submit[action.command] then
          vim.schedule(function()
            vim.api.nvim_input("<Esc>")
            agent.chat.ui:lock_buf()
          end)
        end
        if action.command == "query" then
          local args = { "query", "--pipe", "-n", tostring(action.options.count) }
          if type(action.options.query) == "string" then
            action.options.query = { action.options.query }
          end
          vim.list_extend(args, action.options.query)
          if action.options.project_root ~= nil then
            action.options.project_root = vim.fs.normalize(action.options.project_root)
            if
              vim.uv.fs_stat(action.options.project_root) ~= nil
              and vim.uv.fs_stat(action.options.project_root).type == "directory"
            then
              vim.list_extend(args, { "--project_root", action.options.project_root })
              vim.list_extend(args, { "--absolute" })
            else
              return {
                status = "error",
                data = "INVALID PROJECT ROOT! USE THE LS COMMAND!",
              }
            end
          end

          if opts.no_duplicate and agent.chat.refs ~= nil then
            -- exclude files that has been added to the context
            local existing_files = { "--exclude" }
            for _, ref in pairs(agent.chat.refs) do
              if ref.source == cc_common.tool_result_source then
                table.insert(existing_files, ref.id)
              end
            end
            if #existing_files > 1 then
              vim.list_extend(args, existing_files)
            end
          end
          logger.info(
            "CodeCompanion query tool called the runner with the following args: ",
            args
          )
          job_runner.run_async(args, function(result, error)
            vim.schedule(function()
              if opts.auto_submit[action.command] then
                agent.chat.ui:unlock_buf()
              end
            end)
            if vim.islist(result) and #result > 0 and result[1].path ~= nil then ---@cast result VectorCode.Result[]
              cb({ status = "success", data = result })
            else
              if type(error) == "table" then
                error = cc_common.flatten_table_to_string(error)
              end
              cb({
                status = "error",
                data = error,
              })
            end
          end, agent.chat.bufnr)
        elseif action.command == "ls" then
          job_runner.run_async({ "ls", "--pipe" }, function(result, error)
            vim.schedule(function()
              if opts.auto_submit[action.command] then
                agent.chat.ui:unlock_buf()
              end
            end)
            if vim.islist(result) and #result > 0 then
              cb({ status = "success", data = result })
            else
              if type(error) == "table" then
                error = cc_common.flatten_table_to_string(error)
              end
              cb({
                status = "error",
                data = error,
              })
            end
          end, agent.chat.bufnr)
        end
      end,
    },
    schema = {
      {
        tool = {
          _attr = { name = "vectorcode" },
          action = {
            command = "query",
            options = {
              query = { "keyword1", "keyword2" },
              count = 5,
            },
          },
        },
      },
      {
        tool = {
          _attr = { name = "vectorcode" },
          action = {
            command = "query",
            options = {
              query = { "keyword1" },
              count = 2,
            },
          },
        },
      },
      {
        tool = {
          _attr = { name = "vectorcode" },
          action = {
            command = "query",
            options = {
              query = { "keyword1" },
              count = 3,
              project_root = "path/to/other/project",
            },
          },
        },
      },
      {
        tool = {
          _attr = { name = "vectorcode" },
          action = {
            command = "ls",
          },
        },
      },
    },
    system_prompt = function(schema, xml2lua)
      local guidelines = {
        "  - Ensure XML is **valid and follows the schema**",
        "  - Make sure the tools xml block is **surrounded by ```xml**",
        "  - The path of a retrieved file will be wrapped in `<path>` and `</path>` tags. Its content will be right after the `</path>` tag, wrapped by `<content>` and `</content>` tags. Do not include the `<path>``</path>` tags in your answers when you mention the paths.",
        "  - If you used the tool, tell users that they may need to wait for the results and there will be a virtual text indicator showing the tool is still running",
        "  - Include one single command call for VectorCode each time. You may include multiple keywords in the command",
        "  - VectorCode is the name of this tool. Do not include it in the query unless the user explicitly asks",
        "  - Use the `ls` command to retrieve a list of indexed project and pick one that may be relevant, unless the user explicitly mentioned 'this project' (or in other equivalent expressions)",
        "  - **The project root option MUST be a valid path on the filesystem. It can only be one of the results from the `ls` command or from user input**",
        capping_message,
        ("  - If the user did not specify how many documents to retrieve, **start with %d documents**"):format(
          opts.default_num
        ),
        "  - If you decide to call VectorCode tool, do not output anything else. Once you have the results, provide answers based on the results and let the user decide whether to run the tool again",
      }
      vim.list_extend(
        guidelines,
        vim.tbl_map(function(line)
          return "  - " .. line
        end, require("vectorcode").prompts())
      )
      if opts.ls_on_start then
        job_runner = cc_common.initialise_runner(opts.use_lsp)
        if job_runner ~= nil then
          vim.list_extend(guidelines, {
            "  - The following projects are indexed by VectorCode and are available for you to search in:",
          })
          vim.list_extend(
            guidelines,
            vim.tbl_map(function(s)
              return string.format("    - %s", s["project-root"])
            end, job_runner.run({ "ls", "--pipe" }, -1, 0))
          )
        end
      end
      local root = vim.fs.root(0, { ".vectorcode", ".git" })
      if root ~= nil then
        vim.list_extend(guidelines, {
          string.format(
            "  - The current working directory is %s. Assume the user query is about this project, unless the user asked otherwise or queries from the current project fails to return useful results.",
            root
          ),
        })
      end
      return string.format(
        [[### VectorCode, a repository indexing and query tool.

1. **Purpose**: This gives you the ability to access the repository to find information that you may need to assist the user.

2. **Usage**: Return an XML markdown code block that retrieves relevant documents corresponding to the generated query.

3. **Key Points**:
%s 

4. **Actions**:

a) **Query for 5 documents using 2 keywords: `keyword1` and `keyword2`**:

```xml
%s
```

b) **Query for 2 documents using one keyword: `keyword1`**:

```xml
%s
```
c) **Query for 3 documents using one keyword: `keyword1` in a different project located at `path/to/other/project` (relative to current working directory)**:
```xml
%s
```
d) **Get all indexed project**
```xml
%s
```

Remember:
- Minimize explanations unless prompted. Focus on generating correct XML.]],
        table.concat(guidelines, "\n"),
        xml2lua.toXml({ tools = { schema[1] } }),
        xml2lua.toXml({ tools = { schema[2] } }),
        xml2lua.toXml({ tools = { schema[3] } }),
        xml2lua.toXml({ tools = { schema[4] } })
      )
    end,
    output = {
      ---@param agent CodeCompanion.Agent
      ---@param cmd table
      ---@param stderr table|string
      error = function(agent, cmd, stderr)
        logger.error(
          ("CodeCompanion tool with command %s thrown with the following error: %s"):format(
            vim.inspect(cmd),
            vim.inspect(stderr)
          )
        )
        stderr = cc_common.flatten_table_to_string(stderr)
        agent.chat:add_message({
          role = "user",
          content = string.format(
            "VectorCode tool failed with the following error:\n```\n%s\n```",
            stderr
          ),
        }, { visible = false })
      end,
      ---@param agent CodeCompanion.Agent
      ---@param cmd table
      ---@param stdout table
      success = function(agent, cmd, stdout)
        stdout = stdout[1]
        logger.info(
          ("CodeCompanion tool with command %s finished."):format(vim.inspect(cmd))
        )
        if cmd.command == "query" then
          agent.chat.ui:unlock_buf()
          for i, file in pairs(stdout) do
            if opts.max_num < 0 or i <= opts.max_num then
              agent.chat:add_message({
                role = "user",
                content = string.format(
                  [[Here is a file the VectorCode tool retrieved:
<path>
%s
</path>
<content>
%s
</content>
]],
                  file.path,
                  file.document
                ),
              }, { visible = false, id = file.path })
              agent.chat.references:add({
                source = cc_common.tool_result_source,
                id = file.path,
                opts = { visible = false },
              })
            end
          end
        elseif cmd.command == "ls" then
          for _, col in pairs(stdout) do
            agent.chat:add_message({
              role = "user",
              content = string.format(
                "<collection>%s</collection>",
                col["project-root"]
              ),
            }, { visible = false })
          end
        end
        if opts.auto_submit[cmd.command] then
          agent.chat:submit()
        end
      end,
    },
  }
end)
