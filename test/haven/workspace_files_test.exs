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
  test "rejects writes outside the workspace", %{tmp_dir: tmp_dir} do
    request = ACP.WriteTextFileRequest.new("session", "../outside.md", "nope")

    assert {:error, %ACP.Error{code: -32602, data: %{"reason" => "outside_workspace"}}} =
             WorkspaceFiles.write_text_file(tmp_dir, request)

    refute File.exists?(Path.expand("../outside.md", tmp_dir))
  end
end
