defmodule Haven.WorkspaceFilesTest do
  use ExUnit.Case, async: true

  alias Haven.WorkspaceFiles

  @tag :tmp_dir
  test "reads text files inside the workspace", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "notes.md"), "one\ntwo\nthree\n")

    request = %ACP.ReadTextFileRequest{
      session_id: "session",
      path: "notes.md",
      line: 2,
      limit: 1
    }

    assert {:ok, "two", path} = WorkspaceFiles.read_text_file(tmp_dir, request)
    assert path == Path.join(tmp_dir, "notes.md")
  end

  @tag :tmp_dir
  test "rejects reads outside the workspace", %{tmp_dir: tmp_dir} do
    request = ACP.ReadTextFileRequest.new("session", "../outside.md")

    assert {:error, %ACP.Error{code: -32602, data: %{"reason" => "outside_workspace"}}} =
             WorkspaceFiles.read_text_file(tmp_dir, request)
  end

  @tag :tmp_dir
  test "writes text files inside the workspace", %{tmp_dir: tmp_dir} do
    request = ACP.WriteTextFileRequest.new("session", "nested/notes.md", "hello\n")

    assert {:ok, path} = WorkspaceFiles.write_text_file(tmp_dir, request)
    assert path == Path.join(tmp_dir, "nested/notes.md")
    assert File.read!(path) == "hello\n"
  end

  @tag :tmp_dir
  test "builds a write diff preview for a new file", %{tmp_dir: tmp_dir} do
    request = ACP.WriteTextFileRequest.new("session", "notes.md", "hello\nworld\n")

    assert %{
             "diff_kind" => "create",
             "diff_preview" => diff,
             "diff_truncated" => false,
             "existing_bytes" => 0
           } = WorkspaceFiles.write_text_file_diff_preview(tmp_dir, request, 1_000)

    assert diff =~ "--- /dev/null"
    assert diff =~ "+++ notes.md"
    assert diff =~ "+hello\n"
    assert diff =~ "+world\n"
    refute File.exists?(Path.join(tmp_dir, "notes.md"))
  end

  @tag :tmp_dir
  test "builds a bounded write diff preview for an existing file", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "notes.md"), "old\n")

    request = ACP.WriteTextFileRequest.new("session", "notes.md", "new\n")

    assert %{
             "diff_kind" => "modify",
             "diff_preview" => diff,
             "diff_preview_limit" => 24,
             "diff_truncated" => true,
             "existing_bytes" => 4
           } = WorkspaceFiles.write_text_file_diff_preview(tmp_dir, request, 24)

    assert String.length(diff) == 24
    assert diff =~ "--- notes.md"
  end

  @tag :tmp_dir
  test "does not read outside the workspace while building a write diff preview", %{
    tmp_dir: tmp_dir
  } do
    request = ACP.WriteTextFileRequest.new("session", "../outside.md", "nope")

    assert %{
             "diff_error" => "outside_workspace",
             "diff_kind" => "unknown",
             "diff_preview" => "",
             "diff_truncated" => false,
             "existing_bytes" => nil
           } = WorkspaceFiles.write_text_file_diff_preview(tmp_dir, request, 1_000)
  end

  @tag :tmp_dir
  test "rejects writes outside the workspace", %{tmp_dir: tmp_dir} do
    request = ACP.WriteTextFileRequest.new("session", "../outside.md", "nope")

    assert {:error, %ACP.Error{code: -32602, data: %{"reason" => "outside_workspace"}}} =
             WorkspaceFiles.write_text_file(tmp_dir, request)

    refute File.exists?(Path.expand("../outside.md", tmp_dir))
  end
end
