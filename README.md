# RangerLink

App de iPhone para la **Ford Ranger PX 3.2 TDCi** que lee datos crudos del puerto OBD-II con un ELM327, los decodifica contra una base de PIDs estándar y de PIDs Ford, y le da a Claude una terminal para que diagnostique la camioneta midiendo en vivo.

```
iPhone ── BLE / Wi-Fi ──> ELM327 ── CAN 500k (pines 6/14) ──> PCM 7E0 · TCM 7E1 · BCM 726 ...
   │
   └── Terminal ──> API de Claude (tool use)
                    Claude decide qué medir → la app lo ejecuta → Claude interpreta
```

## Lo que tienes que saber antes

1. **La base de FORScan no está aquí porque no se puede extraer.** Es propietaria y viene cifrada dentro del programa. En su lugar hay:
   - `pids/obd2_mode01.json`: 46 señales estándar SAE J1979 relevantes para un diésel.
   - `pids/ranger_px_mode22.json`: 49 DIDs Ford UDS (servicio 22) y 6 candidatos sin fórmula. Vienen de logs reales de PX en [OBDb/Ford-Ranger](https://github.com/OBDb/Ford-Ranger), del foro Ranger Mods y de los X-Gauge de ScanGauge para el Transit 3.2, que lleva el mismo motor.

   Cada señal trae su nivel de `confidence`:

   | Nivel | Qué significa |
   |---|---|
   | `sae-standard` | Viene de la norma. Funciona si la PCM lo reporta en su máscara de soporte. |
   | `confirmed-ranger` | Alguien lo vio responder en una PX, Everest o BT-50 3.2. |
   | `ford-diesel-sibling` | Probado en el Transit 3.2. La escala puede estar mal, así que valídalo. |
   | `ford-generic` | Convención Ford sin verificar en esta camioneta. |

2. **El ejemplo de los inyectores depende de DIDs sin confirmar en la PX.** Los DIDs de balance por cilindro (`6043`, `6063`, `6049`, `6069` y `3037`) vienen del Transit 3.2. Su escala es una hipótesis, y el del cilindro 5 no sigue el patrón de los otros. Claude tiene instrucciones de tratarlos como hipótesis, cruzarlos con señales conocidas y recomendar una prueba física de retorno antes de condenar un inyector.

3. **Un ELM327 Bluetooth "clásico" no sirve en iPhone.** iOS sólo permite Bluetooth clásico (SPP) a accesorios con certificación MFi, así que necesitas uno **BLE** (Vgate iCar Pro BLE, OBDLink CX/MX+, Veepeak BLE) o uno Wi-Fi.

4. **Con un ELM327 genérico sólo llegas al HS-CAN.** Eso cubre la PCM, el TCM (6R80) y el BCM/TPMS. Para los módulos de MS-CAN (pines 3/11) necesitas un adaptador que conmute de bus.

5. **La PCM del PX es una Continental SID208**, y la de los PX2/PX3 de 200 hp es una SID209. No es Bosch EDC17, así que las listas del 6.7 Power Stroke no aplican.

## Estructura

```
pids/                      Base de PIDs (JSON), la fuente de verdad
tools/pidtool.py           Valida la base, decodifica respuestas y lista PIDs
tools/elm327_sim.py        ELM327 falso por TCP para probar sin la camioneta
ios/project.yml            Proyecto Xcode (XcodeGen)
ios/OBDCore/               Paquete Swift sin UI, con pruebas y compatible con Linux
  Formula.swift            Fórmulas estilo Torque (A, B, s16(), u32(), bit()...)
  ELMResponse.swift        Parser de respuestas del ELM327 y reensamblado ISO-TP multi-frame
  ELM327.swift             Sesión (actor): inicialización, cabeceras, lectura, muestreo, DTCs
  SafetyGuard.swift        Lista de comandos permitidos, sólo lectura
  SimulatedELM327.swift    Camioneta simulada (modo Demo)
  ClaudeClient.swift       Messages API por HTTP (Swift no tiene SDK oficial)
  AgentToolbox.swift       Herramientas que Claude puede ejecutar
  DiagnosticAgent.swift    Ciclo agéntico y system prompt
ios/App/RangerLink/        App SwiftUI: conexión, en vivo, terminal Claude, log crudo, ajustes
```

## Herramientas que tiene Claude

| Herramienta | Qué hace |
|---|---|
| `vehicle_info` | Adaptador, protocolo, voltaje, VIN y PIDs de modo 01 soportados |
| `search_pids` | Detalle de la base: fórmula, fuentes, notas y confianza |
| `read_pids` | Lee una vez varios PIDs (valor decodificado más el hex crudo) |
| `sample_pids` | Registra en vivo durante N segundos y devuelve min, max, media, desviación y serie |
| `read_did` / `scan_dids` | Explora DIDs que no están en la base, para descubrir PIDs propietarios |
| `read_dtcs` | Lee DTCs OBD y UDS `19 02` por módulo |
| `send_raw` | Manda un comando crudo, filtrado por `SafetyGuard` |
| `ask_driver` | Pide una condición al usuario ("mantén 2000 rpm") y espera a que toque Listo |

**Seguridad:**
- Sólo se permiten servicios de lectura: `01 02 03 06 07 09 0A 19 22`.
- Borrar DTCs (`04`/`14`) o abrir la sesión extendida (`10 03`) siempre muestra una confirmación en pantalla.
- Están bloqueados sin excepción: escritura (`2E`), rutinas (`31`), I/O (`2F`), seguridad (`27`), reset (`11`), programación (`34`–`37`) y comandos AT que alteran el adaptador (`ATPP`, `ATBRD`, `ATMA`).

## Correrlo

**En el iPhone** (necesitas una Mac con Xcode 15 o posterior):

```bash
brew install xcodegen
cd ios && xcodegen generate && open RangerLink.xcodeproj
```

Luego:
1. Pon tu Team en *Signing & Capabilities* y compila en el iPhone.
2. En la app, ve a Ajustes y pega tu API key de Anthropic. Se guarda en el Keychain.
3. Ve a Conexión, elige tu adaptador BLE y pon el encendido en ON o el motor en marcha.
4. En la pestaña Claude escribe, por ejemplo: *"Revisa el balance de los 5 inyectores en ralentí y dime si alguno está fallando"*.

En la terminal, `> 22 F4 5C` manda un comando crudo sin pasar por Claude, y `/reset` borra la conversación.

**Sin camioneta:**
- Modo Demo: una Ranger simulada en la que el cilindro 5 tiene una corrección anormal.
- O en tu Mac corre `python3 tools/elm327_sim.py` y conecta la app por Wi-Fi a la IP de la Mac, puerto 35000.

**Herramientas y pruebas:**

```bash
python3 tools/pidtool.py validate
python3 tools/pidtool.py decode OBD.01.0C "41 0C 1A F8"   # → 1726 rpm
python3 tools/pidtool.py list dpf
python3 -m unittest discover -s tools/tests
swift test --package-path ios/OBDCore                        # macOS o Linux
```

## Modelo y costo

El modelo por defecto es `claude-opus-5` con pensamiento adaptativo y `fallbacks: "default"`. Esto último hace que, si un clasificador de seguridad rechaza la petición, se reintente en otro modelo. Desde Ajustes puedes cambiar a `claude-sonnet-5` o `claude-haiku-4-5`, que son más baratos.

Cada diagnóstico son varias llamadas: una por cada ronda de herramientas. El prompt se cachea para bajar el costo de las siguientes.

La API key vive en el teléfono. Para un uso personal está bien. Si la vas a compartir, pon un proxy propio y cambia `baseURL` en `ClaudeConfig`.

## Cómo agregar PIDs

Agrega una entrada a `pids/*.json` con `formula` en términos de A, B, C… (los bytes después del eco `62 DID`), su `confidence`, sus `sources` y de preferencia un `test` con una respuesta real. `pidtool.py validate` y los tests de Swift verifican el mismo vector.

Si descubres un DID con `scan_dids`, anótalo primero en `candidates` hasta que su escala esté verificada.

## Pendiente / ideas

- Validar en la camioneta los DIDs `ford-diesel-sibling` (inyectores, riel `9DA2`, EGT `9DD4`) y corregir escalas.
- Soporte de MS-CAN con adaptadores que conmutan de bus (comandos STN de OBDLink).
- Exportar sesiones de muestreo a CSV para compararlas en el tiempo.
