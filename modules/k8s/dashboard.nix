# Hydra CI Grafana dashboard — extracted from nixlab's
# modules/k8s/monitoring/hydra-dashboard.nix. Parameterized:
#   - `instance` label (was hardcoded to "hydra") is now an option
#   - `namespace` is now an option (was hardcoded to "monitoring")
#   - `folder` is now an option (was hardcoded to "Infrastructure")
#   - dashboard gated behind `cfg.enable` (was always-on)
#
# Dashboard JSON shape is unchanged: same panels, same PromQL (modulo the
# parameterized instance label), same thresholds, same transformations.
#
# Consumer supplies `instance` matching the `instance=` label its
# prometheus scrape job assigns to the Hydra target.
{ lib, config, ... }:
let
  cfg = config.services.casazza-hydra.dashboard;

  hydraInstance = cfg.instance;
  namespace = cfg.namespace;

  # Matches the convention used in network-security.nix and
  # game-server-dashboard.nix. The grafana-operator Prometheus datasource
  # does not set an explicit uid, so Grafana assigns this UUID.
  promDs = {
    type = "prometheus";
    uid = "prometheus";
  };

  # Common threshold definitions ----------------------------------------------
  upDownThresholds = {
    mode = "absolute";
    steps = [
      {
        color = "red";
        value = null;
      }
      {
        color = "green";
        value = 1;
      }
    ];
  };

  percentThresholds = {
    mode = "absolute";
    steps = [
      {
        color = "green";
        value = null;
      }
      {
        color = "yellow";
        value = 70;
      }
      {
        color = "red";
        value = 85;
      }
    ];
  };

  # Map a systemd unit to a stat panel showing its "active" state value.
  # The `node_systemd_unit_state{state="active"}` metric is 1 when the unit
  # is running, 0 otherwise.
  systemdStatPanel =
    {
      id,
      title,
      unit,
      x,
      y,
    }:
    {
      inherit id title;
      type = "stat";
      datasource = promDs;
      gridPos = {
        h = 4;
        w = 4;
        inherit x y;
      };
      targets = [
        {
          datasource = promDs;
          expr = ''node_systemd_unit_state{instance="${hydraInstance}",name="${unit}",state="active"}'';
          legendFormat = unit;
          refId = "A";
          instant = true;
        }
      ];
      options = {
        reduceOptions = {
          calcs = [ "lastNotNull" ];
          fields = "";
          values = false;
        };
        colorMode = "background";
        graphMode = "none";
        textMode = "value_and_name";
      };
      fieldConfig.defaults = {
        thresholds = upDownThresholds;
        mappings = [
          {
            type = "value";
            options = {
              "0".text = "DOWN";
              "1".text = "UP";
            };
          }
        ];
      };
    };

  dashboardJson = builtins.toJSON {
    annotations.list = [
      {
        builtIn = 1;
        datasource = {
          type = "grafana";
          uid = "-- Grafana --";
        };
        enable = true;
        hide = true;
        iconColor = "rgba(0, 211, 255, 1)";
        name = "Annotations & Alerts";
        type = "dashboard";
      }
    ];
    editable = true;
    fiscalYearStartMonth = 0;
    graphTooltip = 1;
    id = null;
    uid = "hydra-ci";
    title = "Hydra CI";
    description = "Hydra CI health. Web-layer metrics from Hydra's Perl middleware, system + systemd unit state from node_exporter.";
    tags = [
      "hydra"
      "ci"
      "infrastructure"
    ];
    links = [
      {
        title = "Hydra UI";
        url = "https://hydra.casazza.io";
        type = "link";
        icon = "external link";
        targetBlank = true;
      }
    ];
    templating.list = [ ];
    time = {
      from = "now-6h";
      to = "now";
    };
    timezone = "browser";
    refresh = "1m";
    schemaVersion = 39;

    panels = [
      # ── Row: Service Health ────────────────────────────────────────────
      {
        type = "row";
        id = 100;
        title = "Service Health";
        collapsed = false;
        gridPos = {
          h = 1;
          w = 24;
          x = 0;
          y = 0;
        };
      }

      (systemdStatPanel {
        id = 1;
        title = "hydra-server";
        unit = "hydra-server.service";
        x = 0;
        y = 1;
      })
      (systemdStatPanel {
        id = 2;
        title = "hydra-evaluator";
        unit = "hydra-evaluator.service";
        x = 4;
        y = 1;
      })
      (systemdStatPanel {
        id = 3;
        title = "hydra-queue-runner";
        unit = "hydra-queue-runner.service";
        x = 8;
        y = 1;
      })
      (systemdStatPanel {
        id = 4;
        title = "hydra-notify";
        unit = "hydra-notify.service";
        x = 12;
        y = 1;
      })
      (systemdStatPanel {
        id = 5;
        title = "postgresql";
        unit = "postgresql.service";
        x = 16;
        y = 1;
      })
      {
        id = 6;
        type = "stat";
        title = "Hydra Exporter Reachable";
        description = "up{job=\"hydra_metrics\"} -- 1 when Prometheus is successfully scraping :3300";
        datasource = promDs;
        gridPos = {
          h = 4;
          w = 4;
          x = 20;
          y = 1;
        };
        targets = [
          {
            datasource = promDs;
            expr = ''up{job="hydra_metrics"}'';
            refId = "A";
            instant = true;
          }
        ];
        options = {
          reduceOptions = {
            calcs = [ "lastNotNull" ];
            fields = "";
            values = false;
          };
          colorMode = "background";
          graphMode = "none";
          textMode = "value";
        };
        fieldConfig.defaults = {
          thresholds = upDownThresholds;
          mappings = [
            {
              type = "value";
              options = {
                "0".text = "DOWN";
                "1".text = "UP";
              };
            }
          ];
        };
      }

      # ── Row: Hydra Web Layer ───────────────────────────────────────────
      {
        type = "row";
        id = 101;
        title = "Hydra Web Layer (from :3300 HTTP middleware)";
        collapsed = false;
        gridPos = {
          h = 1;
          w = 24;
          x = 0;
          y = 5;
        };
      }

      # Request rate per controller
      {
        id = 7;
        type = "timeseries";
        title = "Request Rate by Controller";
        description = "HTTP requests/sec grouped by Hydra controller. Source: http_requests_total";
        datasource = promDs;
        gridPos = {
          h = 8;
          w = 12;
          x = 0;
          y = 6;
        };
        targets = [
          {
            datasource = promDs;
            expr = ''sum by (controller) (rate(http_requests_total{instance="${hydraInstance}"}[5m]))'';
            legendFormat = "{{controller}}";
            refId = "A";
          }
        ];
        fieldConfig.defaults = {
          unit = "reqps";
          custom = {
            drawStyle = "line";
            fillOpacity = 20;
            lineWidth = 1;
            showPoints = "never";
          };
        };
        options.legend = {
          displayMode = "table";
          placement = "bottom";
          calcs = [
            "mean"
            "max"
          ];
        };
      }

      # Status-code timeseries (success vs 4xx/5xx)
      {
        id = 8;
        type = "timeseries";
        title = "Response Status Codes";
        description = "Requests/sec split by 2xx / 4xx / 5xx";
        datasource = promDs;
        gridPos = {
          h = 8;
          w = 12;
          x = 12;
          y = 6;
        };
        targets = [
          {
            datasource = promDs;
            expr = ''sum(rate(http_requests_total{instance="${hydraInstance}",code=~"2.."}[5m]))'';
            legendFormat = "2xx";
            refId = "A";
          }
          {
            datasource = promDs;
            expr = ''sum(rate(http_requests_total{instance="${hydraInstance}",code=~"3.."}[5m]))'';
            legendFormat = "3xx";
            refId = "B";
          }
          {
            datasource = promDs;
            expr = ''sum(rate(http_requests_total{instance="${hydraInstance}",code=~"4.."}[5m]))'';
            legendFormat = "4xx";
            refId = "C";
          }
          {
            datasource = promDs;
            expr = ''sum(rate(http_requests_total{instance="${hydraInstance}",code=~"5.."}[5m]))'';
            legendFormat = "5xx";
            refId = "D";
          }
        ];
        fieldConfig.defaults = {
          unit = "reqps";
          custom = {
            drawStyle = "line";
            fillOpacity = 30;
            lineWidth = 1;
            stacking.mode = "normal";
            showPoints = "never";
          };
        };
      }

      # Latency percentiles
      {
        id = 9;
        type = "timeseries";
        title = "Request Latency (p50 / p95 / p99)";
        description = "Derived from http_request_duration_seconds histogram";
        datasource = promDs;
        gridPos = {
          h = 8;
          w = 12;
          x = 0;
          y = 14;
        };
        targets = [
          {
            datasource = promDs;
            expr = ''histogram_quantile(0.50, sum by (le) (rate(http_request_duration_seconds_bucket{instance="${hydraInstance}"}[5m])))'';
            legendFormat = "p50";
            refId = "A";
          }
          {
            datasource = promDs;
            expr = ''histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{instance="${hydraInstance}"}[5m])))'';
            legendFormat = "p95";
            refId = "B";
          }
          {
            datasource = promDs;
            expr = ''histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{instance="${hydraInstance}"}[5m])))'';
            legendFormat = "p99";
            refId = "C";
          }
        ];
        fieldConfig.defaults = {
          unit = "s";
          custom = {
            drawStyle = "line";
            fillOpacity = 10;
            lineWidth = 1;
            showPoints = "never";
          };
        };
      }

      # Error ratio stat
      {
        id = 10;
        type = "stat";
        title = "Error Ratio (5xx / total, 1h)";
        description = "Fraction of requests returning 5xx in the last hour";
        datasource = promDs;
        gridPos = {
          h = 4;
          w = 6;
          x = 12;
          y = 14;
        };
        targets = [
          {
            datasource = promDs;
            expr = ''sum(rate(http_requests_total{instance="${hydraInstance}",code=~"5.."}[1h])) / clamp_min(sum(rate(http_requests_total{instance="${hydraInstance}"}[1h])), 1e-9)'';
            refId = "A";
            instant = true;
          }
        ];
        fieldConfig.defaults = {
          unit = "percentunit";
          decimals = 3;
          thresholds = {
            mode = "absolute";
            steps = [
              {
                color = "green";
                value = null;
              }
              {
                color = "yellow";
                value = 0.01;
              }
              {
                color = "red";
                value = 0.05;
              }
            ];
          };
        };
        options = {
          reduceOptions.calcs = [ "lastNotNull" ];
          colorMode = "value";
          graphMode = "area";
        };
      }

      # Total requests (24h) stat
      {
        id = 11;
        type = "stat";
        title = "Total Requests (24h)";
        datasource = promDs;
        gridPos = {
          h = 4;
          w = 6;
          x = 18;
          y = 14;
        };
        targets = [
          {
            datasource = promDs;
            expr = ''sum(increase(http_requests_total{instance="${hydraInstance}"}[24h]))'';
            refId = "A";
            instant = true;
          }
        ];
        fieldConfig.defaults = {
          unit = "short";
          decimals = 0;
          thresholds = {
            mode = "absolute";
            steps = [
              {
                color = "blue";
                value = null;
              }
            ];
          };
        };
        options = {
          reduceOptions.calcs = [ "lastNotNull" ];
          colorMode = "value";
          graphMode = "area";
        };
      }

      # Top endpoints table
      {
        id = 12;
        type = "table";
        title = "Top Endpoints by Request Volume (1h)";
        description = "Requests per controller/action. Helps identify hot paths and API usage.";
        datasource = promDs;
        gridPos = {
          h = 8;
          w = 12;
          x = 12;
          y = 18;
        };
        targets = [
          {
            datasource = promDs;
            expr = ''topk(15, sum by (controller, action, method) (increase(http_requests_total{instance="${hydraInstance}"}[1h])))'';
            refId = "A";
            instant = true;
            format = "table";
          }
        ];
        fieldConfig = {
          defaults = { };
          overrides = [
            {
              matcher = {
                id = "byName";
                options = "Value";
              };
              properties = [
                {
                  id = "displayName";
                  value = "requests/1h";
                }
                {
                  id = "unit";
                  value = "short";
                }
              ];
            }
          ];
        };
        options.footer.enablePagination = false;
      }

      # ── Row: Host Infrastructure ───────────────────────────────────────
      {
        type = "row";
        id = 102;
        title = "Host Infrastructure";
        collapsed = false;
        gridPos = {
          h = 1;
          w = 24;
          x = 0;
          y = 26;
        };
      }

      # Root disk usage gauge
      {
        id = 13;
        type = "gauge";
        title = "Root Disk Usage";
        description = "Percent used on /";
        datasource = promDs;
        gridPos = {
          h = 6;
          w = 6;
          x = 0;
          y = 27;
        };
        targets = [
          {
            datasource = promDs;
            expr = ''100 * (1 - (node_filesystem_avail_bytes{instance="${hydraInstance}",mountpoint="/"} / node_filesystem_size_bytes{instance="${hydraInstance}",mountpoint="/"}))'';
            refId = "A";
            instant = true;
          }
        ];
        fieldConfig.defaults = {
          unit = "percent";
          min = 0;
          max = 100;
          thresholds = percentThresholds;
        };
      }

      # Memory usage gauge
      {
        id = 14;
        type = "gauge";
        title = "Memory Usage";
        description = "MemTotal - MemAvailable as % of total";
        datasource = promDs;
        gridPos = {
          h = 6;
          w = 6;
          x = 6;
          y = 27;
        };
        targets = [
          {
            datasource = promDs;
            expr = ''100 * (1 - (node_memory_MemAvailable_bytes{instance="${hydraInstance}"} / node_memory_MemTotal_bytes{instance="${hydraInstance}"}))'';
            refId = "A";
            instant = true;
          }
        ];
        fieldConfig.defaults = {
          unit = "percent";
          min = 0;
          max = 100;
          thresholds = percentThresholds;
        };
      }

      # CPU usage stat
      {
        id = 15;
        type = "stat";
        title = "CPU Usage (5m avg)";
        description = "Percent of CPU time not spent idle";
        datasource = promDs;
        gridPos = {
          h = 6;
          w = 6;
          x = 12;
          y = 27;
        };
        targets = [
          {
            datasource = promDs;
            expr = ''100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{instance="${hydraInstance}",mode="idle"}[5m])))'';
            refId = "A";
            instant = true;
          }
        ];
        fieldConfig.defaults = {
          unit = "percent";
          thresholds = percentThresholds;
        };
        options = {
          reduceOptions.calcs = [ "lastNotNull" ];
          colorMode = "background";
          graphMode = "area";
        };
      }

      # Uptime stat
      {
        id = 16;
        type = "stat";
        title = "Host Uptime";
        datasource = promDs;
        gridPos = {
          h = 6;
          w = 6;
          x = 18;
          y = 27;
        };
        targets = [
          {
            datasource = promDs;
            expr = ''time() - node_boot_time_seconds{instance="${hydraInstance}"}'';
            refId = "A";
            instant = true;
          }
        ];
        fieldConfig.defaults = {
          unit = "s";
          thresholds = {
            mode = "absolute";
            steps = [
              {
                color = "blue";
                value = null;
              }
            ];
          };
        };
        options = {
          reduceOptions.calcs = [ "lastNotNull" ];
          colorMode = "value";
          graphMode = "none";
        };
      }

      # CPU usage timeseries (by mode)
      {
        id = 17;
        type = "timeseries";
        title = "CPU Utilisation by Mode";
        datasource = promDs;
        gridPos = {
          h = 8;
          w = 12;
          x = 0;
          y = 33;
        };
        targets = [
          {
            datasource = promDs;
            expr = ''avg by (mode) (rate(node_cpu_seconds_total{instance="${hydraInstance}",mode!="idle"}[5m]))'';
            legendFormat = "{{mode}}";
            refId = "A";
          }
        ];
        fieldConfig.defaults = {
          unit = "percentunit";
          custom = {
            drawStyle = "line";
            fillOpacity = 30;
            stacking.mode = "normal";
            lineWidth = 1;
            showPoints = "never";
          };
        };
      }

      # Memory timeseries
      {
        id = 18;
        type = "timeseries";
        title = "Memory Breakdown";
        datasource = promDs;
        gridPos = {
          h = 8;
          w = 12;
          x = 12;
          y = 33;
        };
        targets = [
          {
            datasource = promDs;
            expr = ''node_memory_MemTotal_bytes{instance="${hydraInstance}"} - node_memory_MemAvailable_bytes{instance="${hydraInstance}"}'';
            legendFormat = "Used";
            refId = "A";
          }
          {
            datasource = promDs;
            expr = ''node_memory_Cached_bytes{instance="${hydraInstance}"}'';
            legendFormat = "Cached";
            refId = "B";
          }
          {
            datasource = promDs;
            expr = ''node_memory_Buffers_bytes{instance="${hydraInstance}"}'';
            legendFormat = "Buffers";
            refId = "C";
          }
          {
            datasource = promDs;
            expr = ''node_memory_MemAvailable_bytes{instance="${hydraInstance}"}'';
            legendFormat = "Available";
            refId = "D";
          }
        ];
        fieldConfig.defaults = {
          unit = "bytes";
          custom = {
            drawStyle = "line";
            fillOpacity = 20;
            lineWidth = 1;
            showPoints = "never";
          };
        };
      }

      # Disk timeseries
      {
        id = 19;
        type = "timeseries";
        title = "Root Filesystem Used %";
        description = "Shows fill trend. Spikes often correlate with /nix/store growth or build artefacts.";
        datasource = promDs;
        gridPos = {
          h = 8;
          w = 12;
          x = 0;
          y = 41;
        };
        targets = [
          {
            datasource = promDs;
            expr = ''100 * (1 - (node_filesystem_avail_bytes{instance="${hydraInstance}",mountpoint="/"} / node_filesystem_size_bytes{instance="${hydraInstance}",mountpoint="/"}))'';
            legendFormat = "/";
            refId = "A";
          }
        ];
        fieldConfig.defaults = {
          unit = "percent";
          min = 0;
          max = 100;
          custom = {
            drawStyle = "line";
            fillOpacity = 20;
            lineWidth = 1;
            showPoints = "never";
          };
        };
      }

      # Network IO
      {
        id = 20;
        type = "timeseries";
        title = "Network IO";
        description = "RX/TX bytes/sec per interface";
        datasource = promDs;
        gridPos = {
          h = 8;
          w = 12;
          x = 12;
          y = 41;
        };
        targets = [
          {
            datasource = promDs;
            expr = ''rate(node_network_receive_bytes_total{instance="${hydraInstance}",device!~"lo|cilium.*|veth.*|cali.*"}[5m])'';
            legendFormat = "rx {{device}}";
            refId = "A";
          }
          {
            datasource = promDs;
            expr = ''-rate(node_network_transmit_bytes_total{instance="${hydraInstance}",device!~"lo|cilium.*|veth.*|cali.*"}[5m])'';
            legendFormat = "tx {{device}}";
            refId = "B";
          }
        ];
        fieldConfig.defaults = {
          unit = "Bps";
          custom = {
            drawStyle = "line";
            fillOpacity = 10;
            lineWidth = 1;
            showPoints = "never";
          };
        };
      }

      # Load average
      {
        id = 21;
        type = "timeseries";
        title = "Load Average";
        datasource = promDs;
        gridPos = {
          h = 6;
          w = 12;
          x = 0;
          y = 49;
        };
        targets = [
          {
            datasource = promDs;
            expr = ''node_load1{instance="${hydraInstance}"}'';
            legendFormat = "1m";
            refId = "A";
          }
          {
            datasource = promDs;
            expr = ''node_load5{instance="${hydraInstance}"}'';
            legendFormat = "5m";
            refId = "B";
          }
          {
            datasource = promDs;
            expr = ''node_load15{instance="${hydraInstance}"}'';
            legendFormat = "15m";
            refId = "C";
          }
        ];
        fieldConfig.defaults = {
          unit = "short";
          custom = {
            drawStyle = "line";
            fillOpacity = 10;
            lineWidth = 1;
            showPoints = "never";
          };
        };
      }

      # Disk IO
      {
        id = 22;
        type = "timeseries";
        title = "Disk IO (read/write)";
        datasource = promDs;
        gridPos = {
          h = 6;
          w = 12;
          x = 12;
          y = 49;
        };
        targets = [
          {
            datasource = promDs;
            expr = ''rate(node_disk_read_bytes_total{instance="${hydraInstance}",device!~"loop.*|dm-.*"}[5m])'';
            legendFormat = "read {{device}}";
            refId = "A";
          }
          {
            datasource = promDs;
            expr = ''-rate(node_disk_written_bytes_total{instance="${hydraInstance}",device!~"loop.*|dm-.*"}[5m])'';
            legendFormat = "write {{device}}";
            refId = "B";
          }
        ];
        fieldConfig.defaults = {
          unit = "Bps";
          custom = {
            drawStyle = "line";
            fillOpacity = 10;
            lineWidth = 1;
            showPoints = "never";
          };
        };
      }

      # ── Row: Systemd Units ─────────────────────────────────────────────
      {
        type = "row";
        id = 103;
        title = "Systemd Units";
        collapsed = false;
        gridPos = {
          h = 1;
          w = 24;
          x = 0;
          y = 55;
        };
      }

      # Hydra daemons -- long-running services that must be `active` at all times.
      {
        id = 23;
        type = "table";
        title = "Hydra Daemons (long-running)";
        description = "Long-running services. Each row should be active (green / UP); anything else is a problem.";
        datasource = promDs;
        gridPos = {
          h = 8;
          w = 12;
          x = 0;
          y = 56;
        };
        targets = [
          {
            datasource = promDs;
            expr = ''node_systemd_unit_state{instance="${hydraInstance}",name=~"hydra-server\\.service|hydra-evaluator\\.service|hydra-queue-runner\\.service|hydra-notify\\.service|postgresql\\.service",state="active"}'';
            refId = "A";
            instant = true;
            format = "table";
          }
        ];
        transformations = [
          {
            id = "organize";
            options = {
              excludeByName = {
                Time = true;
                __name__ = true;
                job = true;
                state = true;
                instance = true;
                type = true;
              };
              renameByName = {
                name = "unit";
                Value = "active";
              };
              indexByName = {
                name = 0;
                Value = 1;
              };
            };
          }
        ];
        fieldConfig = {
          defaults = { };
          overrides = [
            {
              matcher = {
                id = "byName";
                options = "active";
              };
              properties = [
                {
                  id = "custom.cellOptions";
                  value = {
                    type = "color-background";
                    mode = "basic";
                  };
                }
                {
                  id = "thresholds";
                  value = upDownThresholds;
                }
                {
                  id = "mappings";
                  value = [
                    {
                      type = "value";
                      options = {
                        "0".text = "DOWN";
                        "1".text = "UP";
                      };
                    }
                  ];
                }
              ];
            }
          ];
        };
      }

      # Failed units count stat -- any hydra unit currently in failed state.
      {
        id = 24;
        type = "stat";
        title = "Failed Hydra Units";
        description = "Count of hydra-* / postgresql units currently in failed state. Non-zero = something needs attention.";
        datasource = promDs;
        gridPos = {
          h = 4;
          w = 6;
          x = 12;
          y = 56;
        };
        targets = [
          {
            datasource = promDs;
            expr = ''sum(node_systemd_unit_state{instance="${hydraInstance}",name=~"hydra-.*|postgresql.*",state="failed"} == 1) or vector(0)'';
            refId = "A";
            instant = true;
          }
        ];
        options = {
          reduceOptions.calcs = [ "lastNotNull" ];
          colorMode = "background";
          graphMode = "none";
          textMode = "value";
        };
        fieldConfig.defaults = {
          unit = "short";
          decimals = 0;
          thresholds = {
            mode = "absolute";
            steps = [
              {
                color = "green";
                value = null;
              }
              {
                color = "red";
                value = 1;
              }
            ];
          };
        };
      }

      # Hydra timer-triggered oneshots. These are `inactive` between firings -- normal.
      # Columns: unit | seconds since last trigger | failed flag.
      {
        id = 25;
        type = "table";
        title = "Hydra Timer Jobs (periodic oneshots)";
        description = ''
          Timer-triggered oneshots. "Last Run" is time since the timer last fired
          (from node_systemd_timer_last_trigger_seconds). These units are expected
          to be `inactive` between firings -- that is normal, not a failure.
          "Last Run" is red when > 25h (most timers run daily; hydra-check-space
          runs every ~15min and hydra-compress-logs weekly, so treat red on those
          with context). "Last Status" flags units whose last invocation failed.
          hydra-declarative-sync has no timer (event-triggered) and will show
          only a status column.
        '';
        datasource = promDs;
        gridPos = {
          h = 10;
          w = 24;
          x = 0;
          y = 64;
        };
        targets = [
          {
            datasource = promDs;
            expr = ''label_replace(time() - node_systemd_timer_last_trigger_seconds{instance="${hydraInstance}",name=~"hydra-(gc|backup|optimise|check-space|compress-logs|update-gc-roots)\\.timer"}, "unit", "$1.service", "name", "hydra-(.+)\\.timer")'';
            refId = "A";
            instant = true;
            format = "table";
          }
          {
            datasource = promDs;
            expr = ''label_replace(node_systemd_unit_state{instance="${hydraInstance}",name=~"hydra-(gc|backup|optimise|declarative-sync|check-space|compress-logs|update-gc-roots)\\.service",state="failed"}, "unit", "$1", "name", "(.+)")'';
            refId = "B";
            instant = true;
            format = "table";
          }
        ];
        transformations = [
          {
            id = "merge";
            options = { };
          }
          {
            id = "organize";
            options = {
              excludeByName = {
                Time = true;
                "Time 1" = true;
                "Time 2" = true;
                __name__ = true;
                "__name__ 1" = true;
                "__name__ 2" = true;
                job = true;
                "job 1" = true;
                "job 2" = true;
                instance = true;
                "instance 1" = true;
                "instance 2" = true;
                name = true;
                "name 1" = true;
                "name 2" = true;
                state = true;
                type = true;
                "type 1" = true;
                "type 2" = true;
              };
              renameByName = {
                unit = "Unit";
                "Value #A" = "Last Run";
                "Value #B" = "Last Status";
              };
              indexByName = {
                unit = 0;
                "Value #A" = 1;
                "Value #B" = 2;
              };
            };
          }
        ];
        fieldConfig = {
          defaults = { };
          overrides = [
            {
              matcher = {
                id = "byName";
                options = "Last Run";
              };
              properties = [
                {
                  id = "unit";
                  value = "s";
                }
                {
                  id = "custom.cellOptions";
                  value = {
                    type = "color-background";
                    mode = "basic";
                  };
                }
                {
                  id = "thresholds";
                  value = {
                    mode = "absolute";
                    steps = [
                      {
                        color = "green";
                        value = null;
                      }
                      {
                        color = "yellow";
                        value = 86400;
                      }
                      {
                        color = "red";
                        value = 90000;
                      }
                    ];
                  };
                }
              ];
            }
            {
              matcher = {
                id = "byName";
                options = "Last Status";
              };
              properties = [
                {
                  id = "custom.cellOptions";
                  value = {
                    type = "color-background";
                    mode = "basic";
                  };
                }
                {
                  id = "thresholds";
                  value = {
                    mode = "absolute";
                    steps = [
                      {
                        color = "green";
                        value = null;
                      }
                      {
                        color = "red";
                        value = 1;
                      }
                    ];
                  };
                }
                {
                  id = "mappings";
                  value = [
                    {
                      type = "value";
                      options = {
                        "0".text = "OK";
                        "1".text = "FAILED";
                      };
                    }
                  ];
                }
              ];
            }
          ];
        };
      }
    ];
  };
in
{
  options.services.casazza-hydra.dashboard = {
    enable = lib.mkEnableOption "Hydra CI Grafana dashboard";

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "monitoring";
      description = "Kubernetes namespace for the GrafanaDashboard CR";
    };

    instance = lib.mkOption {
      type = lib.types.str;
      default = "hydra";
      description = ''
        Prometheus `instance=` label value used in Hydra queries. Must match
        the scrape job target in the consumer's prometheus.nix (the label
        Prometheus assigns to the Hydra target, typically the job name or
        host:port).
      '';
    };

    folder = lib.mkOption {
      type = lib.types.str;
      default = "Infrastructure";
      description = "Grafana folder for the dashboard";
    };
  };

  config = lib.mkIf cfg.enable {
    kubernetes.objects = [
      {
        apiVersion = "grafana.integreatly.org/v1beta1";
        kind = "GrafanaDashboard";
        metadata = {
          name = "hydra-ci";
          inherit namespace;
          labels.app = "grafana";
        };
        spec = {
          instanceSelector.matchLabels.dashboards = "grafana";
          folder = cfg.folder;
          json = dashboardJson;
        };
      }
    ];
  };
}
