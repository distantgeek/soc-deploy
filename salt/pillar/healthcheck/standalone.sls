healthcheck:
  enabled: True
  schedule: 300
  checks:
    - zeek
    - fleet_image
  fleet_image:
    expected_id: sha256:c786ed0c4c389d7a3074ebeb86b33c7319ae9dbac22be8ed106fd836688694b6
    heal: True