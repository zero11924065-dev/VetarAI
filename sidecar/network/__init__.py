"""Network egress guard (P1-3).

Contract: EVERY outbound HTTP request made by the Agent MUST pass through
`guard_request(host)`. See guard.py for the full contract.
"""
from sidecar.network.guard import is_local_or_cn, guard_request, assert_guard, NetworkGuardError
