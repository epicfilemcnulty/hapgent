[Unit]
Description=HAProxy Agent
After=network.target

[Service]
Type=simple
User={{ hapgent_user }}
Environment=HAPGENT_STATE_FILE={{ hapgent_state_file }}
Environment=HAPGENT_IP={{ hapgent_ip }}
Environment=HAPGENT_PORT={{ hapgent_port }}
ExecStart=/usr/local/bin/hapgent

[Install]
WantedBy=multi-user.target
