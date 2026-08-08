"""
Simulation du controleur partition-aware (Contribution 2)
Compare 3 politiques de detection de panne :
  - conservative : seuil fixe par defaut du moteur (10s MongoDB, 3s PXC)
  - aggressive   : seuil fixe abaisse naivement pour un RTO plus rapide
  - adaptive     : seuil variable style Jacobson (SRTT + k*RTTVAR), comme
                    l'estimation du RTO TCP

Calibre sur les vraies donnees du scenario 3 (courbes de seuil mesurees
empiriquement sur MongoDB et PXC dans la campagne experimentale).
"""
import numpy as np

rng = np.random.default_rng(42)


def generate_episode(kind, threshold_s, base_rtt=0.15, duration_s=90, step_s=0.2):
    """kind: 'jitter' (degradation transitoire, ne doit jamais declencher)
    ou 'partition' (panne franche et soutenue, doit toujours declencher)"""
    n = int(duration_s / step_s)
    rtt = base_rtt + rng.normal(0, 0.03, n).clip(min=0.01)
    is_partition = np.zeros(n, dtype=bool)

    if kind == "jitter":
        n_spikes = rng.integers(1, 4)
        for _ in range(n_spikes):
            spike_start = rng.integers(5, n - int(5 / step_s))
            spike_len = int(rng.uniform(1.0, threshold_s * 0.6) / step_s)
            spike_level = rng.uniform(threshold_s * 0.3, threshold_s * 0.75)
            end = min(spike_start + spike_len, n)
            rtt[spike_start:end] = spike_level + rng.normal(
                0, spike_level * 0.15, end - spike_start
            ).clip(min=-spike_level * 0.3)
        rtt = rtt.clip(min=0.01)

    elif kind == "partition":
        onset = rng.integers(5, n // 3)
        rtt[onset:] = rng.uniform(threshold_s * 1.5, threshold_s * 3.0, n - onset)
        is_partition[onset:] = True

    return rtt, is_partition, step_s


def static_detector(rtt, step_s, fixed_threshold_s):
    """Detecteur a seuil fixe, modele 'timer' : declenche apres une
    absence de contact continue >= seuil (fidele au fonctionnement reel
    des timeouts heartbeat/election)."""
    n = len(rtt)
    triggered = np.zeros(n, dtype=bool)
    time_since_ok = 0.0
    for i in range(n):
        if rtt[i] > step_s:
            time_since_ok += step_s
        else:
            time_since_ok = 0.0
        if time_since_ok >= fixed_threshold_s:
            triggered[i] = True
    return triggered


def adaptive_detector(
    rtt, step_s, base_threshold_s,
    alpha=0.125, beta=0.25, k=4.0,
    min_timeout_frac=0.3, max_timeout_mult=1.5, sanity_cap_mult=1.3,
):
    """Detecteur adaptatif style Jacobson (estimation du RTO TCP) :
    seuil = SRTT + k*RTTVAR, recalcule en continu. Les echantillons
    au-dela du plafond de bon sens (sanity_cap) sont exclus de la mise
    a jour, pour eviter qu'une vraie panne ne 'gonfle' le seuil au point
    de se tolerer elle-meme."""
    n = len(rtt)
    triggered = np.zeros(n, dtype=bool)
    srtt = max(rtt[0], 0.05)
    rttvar = srtt / 2
    time_since_ok = 0.0
    sanity_cap = base_threshold_s * sanity_cap_mult
    min_timeout = base_threshold_s * min_timeout_frac

    for i in range(n):
        adaptive_threshold = np.clip(
            srtt + k * rttvar, min_timeout, base_threshold_s * max_timeout_mult
        )
        if rtt[i] > step_s:
            time_since_ok += step_s
        else:
            time_since_ok = 0.0
        if rtt[i] < sanity_cap:
            err = rtt[i] - srtt
            srtt = srtt + alpha * err
            rttvar = rttvar + beta * (abs(err) - rttvar)
        if time_since_ok >= adaptive_threshold:
            triggered[i] = True
    return triggered


def run_campaign(base_threshold_s, aggressive_frac=0.35, n_per_kind=500):
    aggressive_threshold_s = base_threshold_s * aggressive_frac
    out = {
        "conservative": {"fp": 0, "tp": 0, "lat": []},
        "aggressive": {"fp": 0, "tp": 0, "lat": []},
        "adaptive": {"fp": 0, "tp": 0, "lat": []},
    }

    for _ in range(n_per_kind):
        rtt, _, step_s = generate_episode("jitter", base_threshold_s)
        if static_detector(rtt, step_s, base_threshold_s).any():
            out["conservative"]["fp"] += 1
        if static_detector(rtt, step_s, aggressive_threshold_s).any():
            out["aggressive"]["fp"] += 1
        if adaptive_detector(rtt, step_s, base_threshold_s).any():
            out["adaptive"]["fp"] += 1

    for _ in range(n_per_kind):
        rtt, is_partition, step_s = generate_episode("partition", base_threshold_s)
        onset_idx = np.argmax(is_partition)
        for name, det in [
            ("conservative", static_detector(rtt, step_s, base_threshold_s)),
            ("aggressive", static_detector(rtt, step_s, aggressive_threshold_s)),
            ("adaptive", adaptive_detector(rtt, step_s, base_threshold_s)),
        ]:
            if det.any():
                out[name]["tp"] += 1
                out[name]["lat"].append((np.argmax(det) - onset_idx) * step_s)

    return out, n_per_kind


if __name__ == "__main__":
    for system, thr in [("MongoDB", 10.0), ("PXC", 3.0)]:
        print(f"\n========== {system} (seuil moteur par defaut = {thr}s) ==========")
        res, n = run_campaign(thr)
        for name in ["conservative", "aggressive", "adaptive"]:
            fp = res[name]["fp"] / n * 100
            tp = res[name]["tp"] / n * 100
            lat = np.mean(res[name]["lat"]) if res[name]["lat"] else float("nan")
            print(
                f"  {name:14s} -- FP gigue: {fp:5.1f}%  "
                f"TP partition: {tp:5.1f}%  latence detection: {lat:5.2f}s"
            )
