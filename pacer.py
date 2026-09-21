import json
from bisect import bisect_left

class SegmentPacer:
    def __init__(self, json_file_path: str):
        with open(json_file_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        self.segment_id = data.get("id", "")
        self.segment_name = data.get("name", "Segmento")
        rabbit_curve = data.get("rabbit_curve", [])
        if not rabbit_curve:
            raise ValueError("El JSON no contiene la clave rabbit_curve")
        self.distances = [p["distance_m"] for p in rabbit_curve]
        self.target_times = [p["elapsed_seconds"] for p in rabbit_curve]

    def get_gap(self, current_dist: float, current_time: float) -> dict:
        if current_dist <= self.distances[0]:
            target_t = self.target_times[0]
        elif current_dist >= self.distances[-1]:
            target_t = self.target_times[-1]
        else:
            idx = bisect_left(self.distances, current_dist)
            x0, x1 = self.distances[idx - 1], self.distances[idx]
            y0, y1 = self.target_times[idx - 1], self.target_times[idx]
            target_t = y0 + (current_dist - x0) * (y1 - y0) / (x1 - x0)
        delta_t = current_time - target_t
        return {
            "segment_name": self.segment_name,
            "current_distance": current_dist,
            "actual_time": current_time,
            "target_time": round(target_t, 2),
            "delta_seconds": round(delta_t, 2),
            "status": "ADELANTADO" if delta_t < 0 else "RETRASADO"
        }
