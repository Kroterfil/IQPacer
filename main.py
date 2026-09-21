import os
from pacer import SegmentPacer

# Ruta al segmento de prueba dentro de segments
segment_path = os.path.join("segments", "karoo_La Montaña desde el tunel.json")

# Inicializamos el motor
pacer = SegmentPacer(segment_path)

print(f"--- Prueba de Pacer: {pacer.segment_name} ---")

# Simulación: a los 1000 metros con 170 segundos recorridos
resultado = pacer.get_gap(current_dist=1000.0, current_time=170.0)

print(f"Distancia actual: {resultado['current_distance']} m")
print(f"Tiempo real: {resultado['actual_time']} s")
print(f"Tiempo de la liebre: {resultado['target_time']} s")
print(f"Diferencia: {resultado['delta_seconds']} s ({resultado['status']})")
