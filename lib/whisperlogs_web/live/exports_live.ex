defmodule WhisperLogsWeb.ExportsLive do
  use WhisperLogsWeb, :live_view

  alias WhisperLogs.Exports
  alias WhisperLogs.Exports.{ExportDestination, Exporter, S3Client}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    destinations = Exports.list_export_destinations(scope)
    jobs = Exports.list_export_jobs(scope, limit: 10)

    {:ok,
     socket
     |> assign(:page_title, "Exports")
     |> assign(:destinations, destinations)
     |> assign(:jobs, jobs)
     |> assign(:show_destination_form, false)
     |> assign(:show_export_modal, false)
     |> assign(:editing_destination, nil)
     |> assign(:selected_destination, nil)
     |> assign(:testing_connection, nil)
     |> assign(:connection_result, nil)
     |> reset_destination_form()
     |> reset_export_form()}
  end

  defp reset_destination_form(socket) do
    assign(
      socket,
      :destination_form,
      to_form(%{
        "name" => "",
        "destination_type" => "local",
        "enabled" => "true",
        "local_path" => "",
        "s3_endpoint" => "",
        "s3_bucket" => "",
        "s3_region" => "",
        "s3_access_key_id" => "",
        "s3_secret_access_key" => "",
        "s3_prefix" => "",
        "auto_export_enabled" => "false",
        "auto_export_age_days" => "7"
      })
    )
  end

  defp reset_export_form(socket) do
    # Default to last 7 days
    to_date = Date.utc_today()
    from_date = Date.add(to_date, -7)

    assign(
      socket,
      :export_form,
      to_form(%{
        "from_date" => Date.to_iso8601(from_date),
        "to_date" => Date.to_iso8601(to_date)
      })
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex-1 overflow-y-auto">
        <div class="max-w-4xl mx-auto px-6 py-8">
          <.header>
            Exports
            <:subtitle>
              Configure export destinations and archive old logs to local storage or S3-compatible services.
            </:subtitle>
          </.header>

          <div class="mt-8 flex items-center gap-3">
            <button
              :if={!@show_destination_form}
              type="button"
              phx-click="show_destination_form"
              class={[
                "flex items-center gap-2 px-4 py-2 rounded-lg font-medium text-sm transition-colors",
                "bg-accent-purple/10 text-accent-purple hover:bg-accent-purple/20",
                "border border-accent-purple/30"
              ]}
            >
              <.icon name="hero-plus" class="size-4" /> Add Destination
            </button>
          </div>

          <%!-- Destination Form --%>
          <div
            :if={@show_destination_form}
            class="mt-6 bg-bg-elevated border border-border-default rounded-lg p-6"
          >
            <div class="flex items-center gap-2 mb-4">
              <.icon name="hero-cloud-arrow-up" class="size-5 text-accent-purple" />
              <h3 class="text-lg font-semibold text-text-primary">
                {if @editing_destination, do: "Edit Destination", else: "New Destination"}
              </h3>
            </div>

            <.form
              for={@destination_form}
              id="destination-form"
              phx-submit="save_destination"
              phx-change="validate_destination"
              class="space-y-4"
            >
              <.input
                field={@destination_form[:name]}
                type="text"
                label="Name"
                placeholder="e.g., Local Backups, S3 Archive"
                phx-debounce="300"
              />

              <.input
                field={@destination_form[:destination_type]}
                type="select"
                label="Destination Type"
                options={[
                  {"Local Folder", "local"},
                  {"S3-Compatible Storage", "s3"}
                ]}
              />

              <%!-- Local settings --%>
              <div :if={@destination_form[:destination_type].value == "local"}>
                <.input
                  field={@destination_form[:local_path]}
                  type="text"
                  label="Local Path"
                  placeholder="/var/log/whisperlogs/exports"
                  phx-debounce="300"
                />
                <p class="mt-1 text-sm text-text-tertiary">
                  Directory where export files will be saved. Will be created if it doesn't exist.
                </p>
              </div>

              <%!-- S3 settings --%>
              <div :if={@destination_form[:destination_type].value == "s3"} class="space-y-4">
                <div class="grid grid-cols-2 gap-4">
                  <.input
                    field={@destination_form[:s3_endpoint]}
                    type="text"
                    label="Endpoint"
                    placeholder="s3.amazonaws.com or s3.us-west-000.backblazeb2.com"
                    phx-debounce="300"
                  />
                  <.input
                    field={@destination_form[:s3_region]}
                    type="text"
                    label="Region"
                    placeholder="us-east-1"
                    phx-debounce="300"
                  />
                </div>
                <.input
                  field={@destination_form[:s3_bucket]}
                  type="text"
                  label="Bucket Name"
                  placeholder="my-logs-bucket"
                  phx-debounce="300"
                />
                <div class="grid grid-cols-2 gap-4">
                  <.input
                    field={@destination_form[:s3_access_key_id]}
                    type="text"
                    label="Access Key ID"
                    phx-debounce="300"
                  />
                  <.input
                    field={@destination_form[:s3_secret_access_key]}
                    type="password"
                    label="Secret Access Key"
                    phx-debounce="300"
                  />
                </div>
                <.input
                  field={@destination_form[:s3_prefix]}
                  type="text"
                  label="Path Prefix (optional)"
                  placeholder="logs/whisperlogs"
                  phx-debounce="300"
                />
                <p class="text-sm text-text-tertiary">
                  Supports AWS S3, Backblaze B2, MinIO, and other S3-compatible services.
                </p>
              </div>

              <div class="border-t border-border-default pt-4 mt-4">
                <h4 class="text-sm font-medium text-text-primary mb-3">Auto-Export Settings</h4>

                <label class="flex items-center gap-3 cursor-pointer">
                  <input
                    type="checkbox"
                    name={@destination_form[:auto_export_enabled].name}
                    value="true"
                    checked={@destination_form[:auto_export_enabled].value == "true"}
                    class="rounded border-border-default text-accent-purple focus:ring-accent-purple"
                  />
                  <span class="text-text-primary">Enable automatic exports</span>
                </label>

                <div :if={@destination_form[:auto_export_enabled].value == "true"} class="mt-3 ml-7">
                  <.input
                    field={@destination_form[:auto_export_age_days]}
                    type="number"
                    label="Export logs older than (days)"
                    min="1"
                    max="365"
                    phx-debounce="300"
                  />
                  <p class="mt-1 text-sm text-text-tertiary">
                    Logs older than this will be exported daily before retention cleanup.
                  </p>
                </div>
              </div>

              <div class="flex gap-3 pt-2">
                <.button variant="primary" phx-disable-with="Saving...">
                  {if @editing_destination, do: "Update Destination", else: "Create Destination"}
                </.button>
                <button
                  type="button"
                  phx-click="hide_destination_form"
                  class="px-4 py-2 text-sm font-medium text-text-secondary hover:text-text-primary rounded-lg transition-colors"
                >
                  Cancel
                </button>
              </div>
            </.form>
          </div>

          <%!-- Destinations List --%>
          <div class="mt-10">
            <h3 class="text-lg font-semibold text-text-primary mb-4">Export Destinations</h3>

            <div class="space-y-3">
              <%= if @destinations == [] do %>
                <div class="flex flex-col items-center justify-center py-12 text-text-tertiary">
                  <.icon name="hero-cloud-arrow-up" class="size-10 mb-3 opacity-50" />
                  <p class="text-text-secondary font-medium">No destinations configured</p>
                  <p class="mt-1 text-sm">Add a destination above to start exporting logs.</p>
                </div>
              <% end %>

              <div
                :for={dest <- @destinations}
                id={"destination-row-#{dest.id}"}
                class="bg-bg-elevated border border-border-default rounded-lg p-4 hover:bg-bg-surface/50 transition-colors"
              >
                <div class="flex items-center justify-between">
                  <div class="flex-1">
                    <div class="flex items-center gap-3">
                      <span class="font-medium text-text-primary">{dest.name}</span>
                      <span class={[
                        "px-2 py-0.5 rounded text-xs font-medium",
                        dest.destination_type == "local" && "bg-blue-500/10 text-blue-400",
                        dest.destination_type == "s3" && "bg-amber-500/10 text-amber-400"
                      ]}>
                        {String.upcase(dest.destination_type)}
                      </span>
                      <span
                        :if={!dest.enabled}
                        class="px-2 py-0.5 rounded text-xs font-medium bg-red-500/10 text-red-400"
                      >
                        DISABLED
                      </span>
                      <span
                        :if={dest.auto_export_enabled}
                        class="px-2 py-0.5 rounded text-xs font-medium bg-green-500/10 text-green-400"
                      >
                        AUTO ({dest.auto_export_age_days}d)
                      </span>
                    </div>
                    <div class="mt-1.5 text-sm text-text-tertiary font-mono">
                      {format_destination_path(dest)}
                    </div>

                    <%!-- Connection test result --%>
                    <div
                      :if={@testing_connection == dest.id}
                      class="mt-2 text-sm text-text-tertiary flex items-center gap-1.5"
                    >
                      <span class="inline-block w-3 h-3 border-2 border-accent-purple/50 border-t-accent-purple rounded-full animate-spin">
                      </span>
                      Testing connection...
                    </div>
                    <div
                      :if={@connection_result && @connection_result.id == dest.id}
                      class="mt-2 text-sm"
                    >
                      <%= if @connection_result.success do %>
                        <span class="text-green-400 flex items-center gap-1.5">
                          <.icon name="hero-check-circle" class="size-4" /> Connection successful
                        </span>
                      <% else %>
                        <span class="text-red-400 flex items-center gap-1.5">
                          <.icon name="hero-x-circle" class="size-4" /> {@connection_result.error}
                        </span>
                      <% end %>
                    </div>
                  </div>
                  <div class="flex items-center gap-2">
                    <button
                      type="button"
                      phx-click="test_connection"
                      phx-value-id={dest.id}
                      class="px-3 py-1.5 text-sm font-medium text-text-secondary hover:text-text-primary hover:bg-bg-surface rounded-lg transition-colors"
                    >
                      Test
                    </button>
                    <button
                      type="button"
                      phx-click="show_export_modal"
                      phx-value-id={dest.id}
                      class="px-3 py-1.5 text-sm font-medium text-accent-purple hover:text-accent-purple-hover hover:bg-accent-purple/10 rounded-lg transition-colors"
                    >
                      Export Now
                    </button>
                    <button
                      type="button"
                      phx-click="edit_destination"
                      phx-value-id={dest.id}
                      class="px-3 py-1.5 text-sm font-medium text-text-secondary hover:text-text-primary hover:bg-bg-surface rounded-lg transition-colors"
                    >
                      Edit
                    </button>
                    <button
                      type="button"
                      phx-click="toggle_enabled"
                      phx-value-id={dest.id}
                      class={[
                        "px-3 py-1.5 text-sm font-medium rounded-lg transition-colors",
                        dest.enabled && "text-amber-400 hover:text-amber-300 hover:bg-amber-500/10",
                        !dest.enabled && "text-green-400 hover:text-green-300 hover:bg-green-500/10"
                      ]}
                    >
                      {if dest.enabled, do: "Disable", else: "Enable"}
                    </button>
                    <button
                      type="button"
                      phx-click="delete_destination"
                      phx-value-id={dest.id}
                      data-confirm="Are you sure you want to delete this destination? All export history will be lost."
                      class="px-3 py-1.5 text-sm font-medium text-red-400 hover:text-red-300 hover:bg-red-500/10 rounded-lg transition-colors"
                    >
                      Delete
                    </button>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <%!-- Export History --%>
          <div class="mt-10">
            <h3 class="text-lg font-semibold text-text-primary mb-4">Export History</h3>

            <div class="bg-bg-elevated border border-border-default rounded-lg overflow-hidden">
              <%= if @jobs == [] do %>
                <div class="flex flex-col items-center justify-center py-12 text-text-tertiary">
                  <.icon name="hero-document-arrow-down" class="size-10 mb-3 opacity-50" />
                  <p class="text-text-secondary font-medium">No exports yet</p>
                  <p class="mt-1 text-sm">Exports will appear here when triggered.</p>
                </div>
              <% else %>
                <table class="w-full">
                  <thead class="bg-bg-surface text-text-tertiary text-xs uppercase tracking-wider">
                    <tr>
                      <th class="px-4 py-3 text-left">File</th>
                      <th class="px-4 py-3 text-left">Status</th>
                      <th class="px-4 py-3 text-left">Logs</th>
                      <th class="px-4 py-3 text-left">Size</th>
                      <th class="px-4 py-3 text-left">Trigger</th>
                      <th class="px-4 py-3 text-left">Date</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-border-default">
                    <tr :for={job <- @jobs} class="hover:bg-bg-surface/50 transition-colors">
                      <td class="px-4 py-3 text-sm font-mono text-text-primary">
                        {job.file_name || "—"}
                      </td>
                      <td class="px-4 py-3">
                        <span class={[
                          "px-2 py-0.5 rounded text-xs font-medium",
                          job.status == "pending" && "bg-yellow-500/10 text-yellow-400",
                          job.status == "running" && "bg-blue-500/10 text-blue-400",
                          job.status == "completed" && "bg-green-500/10 text-green-400",
                          job.status == "failed" && "bg-red-500/10 text-red-400"
                        ]}>
                          {String.upcase(job.status)}
                        </span>
                        <span
                          :if={job.status == "failed" && job.error_message}
                          class="block mt-1 text-xs text-red-400 max-w-xs truncate"
                          title={job.error_message}
                        >
                          {job.error_message}
                        </span>
                      </td>
                      <td class="px-4 py-3 text-sm text-text-secondary">
                        {format_count(job.log_count)}
                      </td>
                      <td class="px-4 py-3 text-sm text-text-secondary">
                        {format_bytes(job.file_size_bytes)}
                      </td>
                      <td class="px-4 py-3 text-sm text-text-tertiary">
                        {job.trigger}
                      </td>
                      <td class="px-4 py-3 text-sm text-text-tertiary">
                        {format_datetime(job.inserted_at)}
                      </td>
                    </tr>
                  </tbody>
                </table>
              <% end %>
            </div>
          </div>

          <%!-- Export Modal --%>
          <div
            :if={@show_export_modal}
            class="fixed inset-0 bg-black/50 flex items-center justify-center z-50"
            phx-click="hide_export_modal"
          >
            <div
              class="bg-bg-elevated border border-border-default rounded-lg p-6 w-full max-w-md"
              phx-click-away="hide_export_modal"
            >
              <div class="flex items-center gap-2 mb-4">
                <.icon name="hero-document-arrow-down" class="size-5 text-accent-purple" />
                <h3 class="text-lg font-semibold text-text-primary">Manual Export</h3>
              </div>

              <p class="text-sm text-text-tertiary mb-4">
                Export logs to:
                <span class="text-text-primary font-medium">
                  {get_destination_name(@selected_destination, @destinations)}
                </span>
              </p>

              <.form
                for={@export_form}
                id="export-form"
                phx-submit="run_export"
                class="space-y-4"
              >
                <input type="hidden" name="destination_id" value={@selected_destination} />

                <div class="grid grid-cols-2 gap-4">
                  <.input
                    field={@export_form[:from_date]}
                    type="date"
                    label="From Date"
                  />
                  <.input
                    field={@export_form[:to_date]}
                    type="date"
                    label="To Date"
                  />
                </div>

                <p class="text-sm text-text-tertiary">
                  Logs within this date range will be exported as a gzipped JSON Lines file.
                </p>

                <div class="flex gap-3 pt-2">
                  <.button variant="primary" phx-disable-with="Starting export...">
                    Start Export
                  </.button>
                  <button
                    type="button"
                    phx-click="hide_export_modal"
                    class="px-4 py-2 text-sm font-medium text-text-secondary hover:text-text-primary rounded-lg transition-colors"
                  >
                    Cancel
                  </button>
                </div>
              </.form>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("show_destination_form", _, socket) do
    {:noreply,
     socket
     |> assign(:show_destination_form, true)
     |> assign(:editing_destination, nil)
     |> assign(:connection_result, nil)
     |> reset_destination_form()}
  end

  def handle_event("hide_destination_form", _, socket) do
    {:noreply,
     socket
     |> assign(:show_destination_form, false)
     |> assign(:editing_destination, nil)
     |> reset_destination_form()}
  end

  def handle_event("validate_destination", params, socket) do
    form_params = Map.drop(params, ["_target"])
    # Handle checkbox - if not present, it's unchecked
    form_params = Map.put_new(form_params, "auto_export_enabled", "false")
    {:noreply, assign(socket, :destination_form, to_form(form_params))}
  end

  def handle_event("save_destination", params, socket) do
    scope = socket.assigns.current_scope

    # Default enabled to true for new destinations (no enabled input in form)
    enabled =
      if socket.assigns.editing_destination,
        do: socket.assigns.editing_destination.enabled,
        else: true

    attrs = %{
      name: params["name"],
      destination_type: params["destination_type"],
      enabled: enabled,
      local_path: params["local_path"],
      s3_endpoint: params["s3_endpoint"],
      s3_bucket: params["s3_bucket"],
      s3_region: params["s3_region"],
      s3_access_key_id: params["s3_access_key_id"],
      s3_secret_access_key: params["s3_secret_access_key"],
      s3_prefix: params["s3_prefix"],
      auto_export_enabled: params["auto_export_enabled"] == "true",
      auto_export_age_days: parse_int(params["auto_export_age_days"])
    }

    result =
      if socket.assigns.editing_destination do
        Exports.update_export_destination(socket.assigns.editing_destination, attrs)
      else
        Exports.create_export_destination(scope, attrs)
      end

    case result do
      {:ok, dest} ->
        destinations =
          if socket.assigns.editing_destination do
            Enum.map(socket.assigns.destinations, fn d ->
              if d.id == dest.id, do: dest, else: d
            end)
          else
            [dest | socket.assigns.destinations]
          end

        {:noreply,
         socket
         |> assign(:destinations, destinations)
         |> assign(:show_destination_form, false)
         |> assign(:editing_destination, nil)
         |> reset_destination_form()
         |> put_flash(
           :info,
           if(socket.assigns.editing_destination,
             do: "Destination updated",
             else: "Destination created"
           )
         )}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, format_errors(changeset))}
    end
  end

  def handle_event("edit_destination", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Exports.get_export_destination(scope, String.to_integer(id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Destination not found")}

      dest ->
        form_data = %{
          "name" => dest.name,
          "destination_type" => dest.destination_type,
          "enabled" => to_string(dest.enabled),
          "local_path" => dest.local_path || "",
          "s3_endpoint" => dest.s3_endpoint || "",
          "s3_bucket" => dest.s3_bucket || "",
          "s3_region" => dest.s3_region || "",
          "s3_access_key_id" => dest.s3_access_key_id || "",
          "s3_secret_access_key" => dest.s3_secret_access_key || "",
          "s3_prefix" => dest.s3_prefix || "",
          "auto_export_enabled" => to_string(dest.auto_export_enabled),
          "auto_export_age_days" => to_string(dest.auto_export_age_days || 7)
        }

        {:noreply,
         socket
         |> assign(:show_destination_form, true)
         |> assign(:editing_destination, dest)
         |> assign(:destination_form, to_form(form_data))}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Exports.get_export_destination(scope, String.to_integer(id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Destination not found")}

      dest ->
        case Exports.toggle_export_destination(dest) do
          {:ok, updated} ->
            destinations =
              Enum.map(socket.assigns.destinations, fn d ->
                if d.id == updated.id, do: %{d | enabled: updated.enabled}, else: d
              end)

            {:noreply, assign(socket, :destinations, destinations)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to update destination")}
        end
    end
  end

  def handle_event("delete_destination", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Exports.get_export_destination(scope, String.to_integer(id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Destination not found")}

      dest ->
        case Exports.delete_export_destination(dest) do
          {:ok, _} ->
            destinations = Enum.reject(socket.assigns.destinations, &(&1.id == dest.id))
            jobs = Enum.reject(socket.assigns.jobs, &(&1.export_destination_id == dest.id))

            {:noreply,
             socket
             |> assign(:destinations, destinations)
             |> assign(:jobs, jobs)
             |> put_flash(:info, "Destination deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete destination")}
        end
    end
  end

  def handle_event("test_connection", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    dest_id = String.to_integer(id)

    case Exports.get_export_destination(scope, dest_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Destination not found")}

      dest ->
        socket =
          socket
          |> assign(:testing_connection, dest_id)
          |> assign(:connection_result, nil)

        # Test connection async
        pid = self()

        Task.start(fn ->
          result = test_destination_connection(dest)
          send(pid, {:connection_test_result, dest_id, result})
        end)

        {:noreply, socket}
    end
  end

  def handle_event("show_export_modal", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:show_export_modal, true)
     |> assign(:selected_destination, String.to_integer(id))
     |> reset_export_form()}
  end

  def handle_event("hide_export_modal", _, socket) do
    {:noreply,
     socket
     |> assign(:show_export_modal, false)
     |> assign(:selected_destination, nil)}
  end

  def handle_event("run_export", params, socket) do
    scope = socket.assigns.current_scope
    dest_id = String.to_integer(params["destination_id"])

    case Exports.get_export_destination(scope, dest_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Destination not found")}

      dest ->
        from_date = Date.from_iso8601!(params["from_date"])
        to_date = Date.from_iso8601!(params["to_date"])

        from_timestamp = DateTime.new!(from_date, ~T[00:00:00], "Etc/UTC")
        to_timestamp = DateTime.new!(to_date, ~T[23:59:59], "Etc/UTC")

        case Exports.create_export_job(dest, scope, %{
               trigger: "manual",
               from_timestamp: from_timestamp,
               to_timestamp: to_timestamp
             }) do
          {:ok, job} ->
            # Run export async
            Exporter.run_export_async(job)

            {:noreply,
             socket
             |> assign(:show_export_modal, false)
             |> assign(:selected_destination, nil)
             |> assign(:jobs, [job | socket.assigns.jobs])
             |> put_flash(:info, "Export started. Refresh the page to see progress.")}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, format_errors(changeset))}
        end
    end
  end

  @impl true
  def handle_info({:connection_test_result, dest_id, result}, socket) do
    {success, error} =
      case result do
        :ok -> {true, nil}
        {:error, reason} -> {false, to_string(reason)}
      end

    {:noreply,
     socket
     |> assign(:testing_connection, nil)
     |> assign(:connection_result, %{id: dest_id, success: success, error: error})}
  end

  defp test_destination_connection(%ExportDestination{destination_type: "local"} = dest) do
    case File.mkdir_p(dest.local_path) do
      :ok -> :ok
      {:error, reason} -> {:error, "Cannot create directory: #{inspect(reason)}"}
    end
  end

  defp test_destination_connection(%ExportDestination{destination_type: "s3"} = dest) do
    S3Client.test_connection(dest)
  end

  defp format_destination_path(%ExportDestination{destination_type: "local"} = dest) do
    dest.local_path || "—"
  end

  defp format_destination_path(%ExportDestination{destination_type: "s3"} = dest) do
    prefix = if dest.s3_prefix && dest.s3_prefix != "", do: "/#{dest.s3_prefix}", else: ""
    "#{dest.s3_bucket}.#{dest.s3_endpoint}#{prefix}"
  end

  defp get_destination_name(nil, _), do: "—"

  defp get_destination_name(id, destinations) do
    case Enum.find(destinations, &(&1.id == id)) do
      nil -> "—"
      dest -> dest.name
    end
  end

  defp format_count(nil), do: "—"
  defp format_count(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_count(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_count(n), do: to_string(n)

  defp format_bytes(nil), do: "—"
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_datetime(nil), do: "—"
  defp format_datetime(dt), do: Calendar.strftime(dt, "%b %d, %Y %H:%M")

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(val) when is_binary(val), do: String.to_integer(val)
  defp parse_int(val) when is_integer(val), do: val

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, messages} -> "#{field}: #{Enum.join(messages, ", ")}" end)
    |> Enum.join("; ")
  end
end
