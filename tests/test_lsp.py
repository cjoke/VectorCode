from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from pygls.exceptions import JsonRpcInvalidRequest
from pygls.server import LanguageServer

from vectorcode import __version__
from vectorcode.cli_utils import CliAction, Config, QueryInclude
from vectorcode.lsp_main import (
    execute_command,
    lsp_start,
    make_caches,
)


@pytest.fixture
def mock_language_server():
    ls = MagicMock(spec=LanguageServer)
    ls.progress.create_async = AsyncMock()
    ls.progress.begin = MagicMock()
    ls.progress.end = MagicMock()
    return ls


@pytest.fixture
def mock_config():
    # config = MagicMock(spec=Config)
    config = Config()
    config.host = "localhost"
    config.port = 8000
    config.action = CliAction.query
    config.project_root = "/test/project"
    config.use_absolute_path = True
    config.pipe = False
    config.overlap_ratio = 0.2
    config.query_exclude = []
    config.include = [QueryInclude.path]
    config.query_multipler = 10
    return config


@pytest.mark.asyncio
async def test_make_caches(tmp_path):
    project_root = str(tmp_path)
    config_file = tmp_path / ".vectorcode" / "config.json"
    config_file.parent.mkdir(exist_ok=True)
    config_file.write_text('{"host": "test_host", "port": 9999}')
    from vectorcode.lsp_main import cached_project_configs

    with (
        patch(
            "vectorcode.lsp_main.get_project_config", new_callable=AsyncMock
        ) as mock_get_project_config,
        patch(
            "vectorcode.lsp_main.try_server", new_callable=AsyncMock
        ) as mock_try_server,
    ):
        mock_try_server.return_value = True
        await make_caches(project_root)

        mock_get_project_config.assert_called_once_with(project_root)
        assert project_root in cached_project_configs


@pytest.mark.asyncio
async def test_make_caches_server_unavailable(tmp_path):
    project_root = str(tmp_path)
    config_file = tmp_path / ".vectorcode" / "config.json"
    config_file.parent.mkdir(exist_ok=True)
    config_file.write_text('{"host": "test_host", "port": 9999}')

    with (
        patch("vectorcode.lsp_main.get_project_config", new_callable=AsyncMock),
        patch(
            "vectorcode.lsp_main.try_server", new_callable=AsyncMock
        ) as mock_try_server,
    ):
        mock_try_server.return_value = False
        with pytest.raises(ConnectionError):
            await make_caches(project_root)


@pytest.mark.asyncio
async def test_execute_command_query(mock_language_server, mock_config):
    with (
        patch(
            "vectorcode.lsp_main.parse_cli_args", new_callable=AsyncMock
        ) as mock_parse_cli_args,
        patch("vectorcode.lsp_main.get_client", new_callable=AsyncMock),
        patch("vectorcode.lsp_main.get_collection", new_callable=AsyncMock),
        patch(
            "vectorcode.lsp_main.build_query_results", new_callable=AsyncMock
        ) as mock_get_query_result_files,
        patch("os.path.isfile", return_value=True),
        patch("vectorcode.lsp_main.try_server", return_value=True),
        patch("builtins.open", MagicMock()) as mock_open,
        patch("vectorcode.lsp_main.cached_project_configs", {}),
    ):
        from vectorcode.lsp_main import cached_project_configs

        cached_project_configs.clear()
        mock_parse_cli_args.return_value = mock_config
        mock_get_query_result_files.return_value = ["/test/file.txt"]

        # Configure the MagicMock object to return a string when read() is called
        mock_file = MagicMock()
        mock_file.__enter__.return_value.read.return_value = "{}"  # Return valid JSON
        mock_open.return_value = mock_file

        # Ensure parsed_args.project_root is not None
        mock_config.project_root = "/test/project"

        # Add a mock config to cached_project_configs
        cached_project_configs["/test/project"] = mock_config

        # Mock the merge_from method
        mock_config.merge_from = AsyncMock(return_value=mock_config)

        result = await execute_command(mock_language_server, ["query", "test"])

        assert isinstance(result, list)
        mock_language_server.progress.begin.assert_called()
        mock_language_server.progress.end.assert_called()


@pytest.mark.asyncio
async def test_execute_command_query_default_proj_root(
    mock_language_server, mock_config
):
    with (
        patch(
            "vectorcode.lsp_main.parse_cli_args", new_callable=AsyncMock
        ) as mock_parse_cli_args,
        patch("vectorcode.lsp_main.get_client", new_callable=AsyncMock),
        patch("vectorcode.lsp_main.get_collection", new_callable=AsyncMock),
        patch(
            "vectorcode.lsp_main.build_query_results", new_callable=AsyncMock
        ) as mock_get_query_result_files,
        patch("os.path.isfile", return_value=True),
        patch("vectorcode.lsp_main.try_server", return_value=True),
        patch("builtins.open", MagicMock()) as mock_open,
        patch("vectorcode.lsp_main.cached_project_configs", {}),
    ):
        from vectorcode.lsp_main import cached_project_configs

        global DEFAULT_PROJECT_ROOT

        mock_config.project_root = None
        cached_project_configs.clear()
        mock_parse_cli_args.return_value = mock_config
        mock_get_query_result_files.return_value = ["/test/file.txt"]

        # Configure the MagicMock object to return a string when read() is called
        mock_file = MagicMock()
        mock_file.__enter__.return_value.read.return_value = "{}"  # Return valid JSON
        mock_open.return_value = mock_file

        # Ensure parsed_args.project_root is not None
        DEFAULT_PROJECT_ROOT = "/test/project"

        # Add a mock config to cached_project_configs
        cached_project_configs["/test/project"] = mock_config

        # Mock the merge_from method
        mock_config.merge_from = AsyncMock(return_value=mock_config)

        result = await execute_command(mock_language_server, ["query", "test"])

        assert isinstance(result, list)
        mock_language_server.progress.begin.assert_called()
        mock_language_server.progress.end.assert_called()


@pytest.mark.asyncio
async def test_execute_command_ls(mock_language_server, mock_config):
    mock_config.action = CliAction.ls
    mock_config.embedding_function = "SentenceTransformerEmbeddingFunction"
    mock_config.embedding_params = {}
    mock_config.db_settings = {}
    mock_config.hnsw = None  # Add the hnsw attribute

    with (
        patch(
            "vectorcode.lsp_main.parse_cli_args", new_callable=AsyncMock
        ) as mock_parse_cli_args,
        patch("vectorcode.lsp_main.get_client", new_callable=AsyncMock),
        patch(
            "vectorcode.lsp_main.get_collection_list", new_callable=AsyncMock
        ) as mock_get_collection_list,
        patch("vectorcode.lsp_main.cached_project_configs", {}),
        patch("vectorcode.common.get_embedding_function") as mock_embedding_function,
        patch("vectorcode.common.get_collection") as mock_get_collection,
        patch("vectorcode.lsp_main.try_server", return_value=True),
    ):
        from vectorcode.lsp_main import cached_project_configs

        cached_project_configs.clear()
        mock_parse_cli_args.return_value = mock_config

        # Ensure parsed_args.project_root is not None
        mock_config.project_root = "/test/project"

        # Add a mock config to cached_project_configs
        cached_project_configs["/test/project"] = mock_config

        # Mock the merge_from method
        mock_config.merge_from = AsyncMock(return_value=mock_config)

        mock_get_collection_list.return_value = [{"project": "/test/project"}]
        mock_embedding_function.return_value = MagicMock()  # Mock embedding function
        mock_get_collection.return_value = MagicMock()

        result = await execute_command(mock_language_server, ["ls"])

        assert isinstance(result, list)
        mock_language_server.progress.begin.assert_called()
        mock_language_server.progress.end.assert_called()


@pytest.mark.asyncio
async def test_execute_command_unsupported_action(
    mock_language_server, mock_config, capsys
):
    mock_config.action = "invalid_action"
    mock_config.project_root = "/test/project"  # Add project_root
    mock_config.embedding_function = "SentenceTransformerEmbeddingFunction"
    mock_config.embedding_params = {}
    mock_config.db_settings = {}
    mock_config.hnsw = None

    with (
        patch(
            "vectorcode.lsp_main.parse_cli_args", new_callable=AsyncMock
        ) as mock_parse_cli_args,
        patch("vectorcode.lsp_main.cached_project_configs", {}),
        patch("vectorcode.lsp_main.try_server", return_value=True),
    ):
        from vectorcode.lsp_main import cached_project_configs

        cached_project_configs.clear()
        mock_parse_cli_args.return_value = mock_config

        # Add a mock config to cached_project_configs
        cached_project_configs["/test/project"] = mock_config

        # Mock the merge_from method
        mock_config.merge_from = AsyncMock(return_value=mock_config)

        with pytest.raises(JsonRpcInvalidRequest):
            await execute_command(mock_language_server, ["invalid_action"])


@pytest.mark.asyncio
async def test_lsp_start_version(capsys):
    with patch("sys.argv", ["lsp_main.py", "--version"]):
        result = await lsp_start()
        captured = capsys.readouterr()
        assert __version__ in captured.out
        assert result == 0


@pytest.mark.asyncio
async def test_lsp_start_no_project_root():
    with patch("sys.argv", ["lsp_main.py"]):
        with (
            patch("vectorcode.lsp_main.find_project_root") as mock_find_project_root,
            patch("asyncio.to_thread") as mock_to_thread,
        ):
            mock_find_project_root.return_value = "/test/project"
            await lsp_start()
            mock_to_thread.assert_called_once()
            from vectorcode.lsp_main import (
                DEFAULT_PROJECT_ROOT,
            )

            assert DEFAULT_PROJECT_ROOT == "/test/project"


@pytest.mark.asyncio
async def test_lsp_start_with_project_root():
    with patch("sys.argv", ["lsp_main.py", "--project_root", "/test/project"]):
        with patch("asyncio.to_thread") as mock_to_thread:
            await lsp_start()
            mock_to_thread.assert_called_once()
            from vectorcode.lsp_main import (
                DEFAULT_PROJECT_ROOT,
            )

            assert DEFAULT_PROJECT_ROOT == "/test/project"


@pytest.mark.asyncio
async def test_lsp_start_find_project_root_none():
    with patch("sys.argv", ["lsp_main.py"]):
        with (
            patch("vectorcode.lsp_main.find_project_root") as mock_find_project_root,
            patch("asyncio.to_thread") as mock_to_thread,
        ):
            mock_find_project_root.return_value = None
            await lsp_start()
            mock_to_thread.assert_called_once()
            from vectorcode.lsp_main import (
                DEFAULT_PROJECT_ROOT,
            )

            assert DEFAULT_PROJECT_ROOT is None


@pytest.mark.asyncio
async def test_execute_command_no_default_project_root(
    mock_language_server, mock_config
):
    global DEFAULT_PROJECT_ROOT
    DEFAULT_PROJECT_ROOT = None
    mock_config.project_root = None
    with (
        patch(
            "vectorcode.lsp_main.parse_cli_args", new_callable=AsyncMock
        ) as mock_parse_cli_args,
        patch("sys.stderr.write") as stderr,
        patch("vectorcode.lsp_main.get_client", new_callable=AsyncMock),
    ):
        mock_parse_cli_args.return_value = mock_config
        await execute_command(mock_language_server, ["query", "test"])
        stderr.assert_called()
    DEFAULT_PROJECT_ROOT = None  # Reset the global variable
