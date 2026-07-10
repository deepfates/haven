defmodule Haven.FileChanges.FileChange do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "file_changes" do
    field :change_id, :string
    field :path, :string
    field :resolved_path, :string
    field :status, :string, default: "pending"
    field :diff_kind, :string, default: "unknown"
    field :bytes, :integer, default: 0
    field :existing_bytes, :integer
    field :content_preview, :string, default: ""
    field :content_preview_limit, :integer, default: 4_000
    field :content_truncated, :boolean, default: false
    field :diff_preview, :string, default: ""
    field :diff_preview_limit, :integer, default: 8_000
    field :diff_truncated, :boolean, default: false
    field :error, :map

    belongs_to :run, Haven.Runs.Run

    timestamps(type: :utc_datetime)
  end

  def changeset(change, attrs) do
    change
    |> cast(attrs, [
      :run_id,
      :change_id,
      :path,
      :resolved_path,
      :status,
      :diff_kind,
      :bytes,
      :existing_bytes,
      :content_preview,
      :content_preview_limit,
      :content_truncated,
      :diff_preview,
      :diff_preview_limit,
      :diff_truncated,
      :error
    ])
    |> validate_required([
      :run_id,
      :change_id,
      :path,
      :status,
      :diff_kind,
      :bytes,
      :content_preview,
      :content_preview_limit,
      :content_truncated,
      :diff_preview,
      :diff_preview_limit,
      :diff_truncated
    ])
    |> validate_inclusion(:status, ["pending", "applied", "denied", "failed", "cancelled"])
    |> unique_constraint([:run_id, :change_id])
  end
end
