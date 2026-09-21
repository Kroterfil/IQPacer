import json
import os

def generate_monkey_c_code():
    segments_dir = "segments"
    
    code_lines = [
        "import Toybox.Lang;",
        "import Toybox.System;",
        "",
        "class SegmentPacerEngine {",
        "    private var _distances as Array<Float>;",
        "    private var _targetTimes as Array<Float>;",
        "    private var _numPoints as Number;",
        "",
        "    public static const SEGMENTS_DATA = {"
    ]
    
    for filename in os.listdir(segments_dir):
        if filename.endswith(".json"):
            path = os.path.join(segments_dir, filename)
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
            
            seg_name = data.get("name", filename.replace(".json", ""))
            rabbit_curve = data.get("rabbit_curve", [])
            
            distances = [round(p["distance_m"], 1) for p in rabbit_curve]
            times = [round(p["elapsed_seconds"], 1) for p in rabbit_curve]
            
            code_lines.append(f"        \"{seg_name}\" => {{")
            code_lines.append(f"            :distances => {distances},")
            code_lines.append(f"            :times => {times}")
            code_lines.append("        },")
            
    code_lines.extend([
        "    };",
        "",
        "    function initialize(segmentName as String) {",
        "        var seg = SEGMENTS_DATA[segmentName];",
        "        if (seg != null) {",
        "            _distances = seg[:distances] as Array<Float>;",
        "            _targetTimes = seg[:times] as Array<Float>;",
        "        } else {",
        "            _distances = [0.0, 100.0] as Array<Float>;",
        "            _targetTimes = [0.0, 10.0] as Array<Float>;",
        "        }",
        "        _numPoints = _distances.size();",
        "    }",
        "",
        "    public function getTargetTime(currentDistance as Float) as Float {",
        "        if (currentDistance <= _distances[0]) {",
        "            return _targetTimes[0];",
        "        }",
        "        if (currentDistance >= _distances[_numPoints - 1]) {",
        "            return _targetTimes[_numPoints - 1];",
        "        }",
        "",
        "        var low = 0;",
        "        var high = _numPoints - 1;",
        "        ",
        "        while (low <= high) {",
        "            var mid = low + (high - low) / 2;",
        "            if (_distances[mid] == currentDistance) {",
        "                return _targetTimes[mid];",
        "            } else if (_distances[mid] < currentDistance) {",
        "                low = mid + 1;",
        "            } else {",
        "                high = mid - 1;",
        "            }",
        "        }",
        "",
        "        var idxLow = high < 0 ? 0 : high;",
        "        var idxHigh = low >= _numPoints ? _numPoints - 1 : low;",
        "        ",
        "        if (idxHigh == idxLow) {",
        "            return _targetTimes[idxLow];",
        "        }",
        "",
        "        var distLow = _distances[idxLow];",
        "        var distHigh = _distances[idxHigh];",
        "        var timeLow = _targetTimes[idxLow];",
        "        var timeHigh = _targetTimes[idxHigh];",
        "",
        "        var factor = (currentDistance - distLow) / (distHigh - distLow);",
        "        return timeLow + factor * (timeHigh - timeLow);",
        "    }",
        "}"
    ])
    
    with open("SegmentPacerEngine.mc", "w", encoding="utf-8") as f:
        f.write("\n".join(code_lines))
        
    print("¡Archivo 'SegmentPacerEngine.mc' generado con éxito!")

if __name__ == "__main__":
    generate_monkey_c_code()
