defmodule Haven.PermissionAudits.PermissionAudit do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "permission_audits" do
    field :request_id, :integer
    field :kind, :string
    field :title, :string
    field :tool_call_id, :string
    field :status, :string, default: "pending"
    field :raw_input, :map
    field :options, :map
    field :selected_option_id, :string
    field :outcome, :string
    field :actor, :string
    field :reason, :string
    field :resolved_at, :utc_datetime_usec

    belongs_to :run, Haven.Runs.Run

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(audit, attrs) do
    audit
    |> cast(attrs, [
      :run_id,
      :request_id,
      :kind,
      :title,
      :tool_call_id,
      :status,
      :raw_input,
      :options,
      :selected_option_id,
      :outcome,
      :actor,
      :reason,
      :resolved_at
    ])
    |> validate_required([:run_id, :request_id, :kind, :status])
    |> validate_inclusion(:status, ["pending", "resolved", "cancelled", "ignored"])
  end
end
