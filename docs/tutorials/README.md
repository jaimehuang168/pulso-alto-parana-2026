# Tutoriales de Pulso 3.1.3

Dos videos en español basados en la aplicación publicada y su manual de 26 secciones. Se usan capturas reales de la interfaz con datos ficticios y narración sintética; no se presentan como una grabación continua ni como una prueba de producción.

## Material aprobado

- Administración de empresa: 560.041 segundos, 1920 × 1080, 17 capítulos, 120 segmentos de subtítulos.
- Encuestadores y usuarios de lectura: 390.529 segundos, 1080 × 1920, 15 capítulos, 81 segmentos de subtítulos.
- Ambos MP4 utilizan H.264/AAC y fueron decodificados por completo sin errores.
- Verificación de reproducción: 25 comprobaciones aprobadas y cero fallos en Chromium, incluidas solicitudes HTTP 206, capítulos, velocidad, subtítulos y anchos de 320, 390 y 768 píxeles.

Captura aislada: run 36353637989. Render y reproducción aprobados: run 36354927426, commit 03a4ed5e427c0c701ff095af0171f6a78f95c2db. Publicación del archivo y descarga de comprobación: run 36355566008.

`release.lock.json` fija el archivo ZIP publicado mediante SHA-256. `deploy.py` descarga ese archivo de un release persistente; `install_bundle.py` verifica todos los archivos antes de instalarlos en `web/tutoriales`. El sitio no depende de que un artefacto temporal de Actions siga disponible. La publicación no altera la base de datos ni las funciones de autenticación de la aplicación.

## Alcance y revisión

No se crean usuarios o entrevistas reales para estos videos. La creación de cuentas se explica con el formulario sin ejecutarla en producción. La imagen de la pantalla en vivo procede de otra prueba aislada y contiene cifras ficticias distintas, tal como explica la narración. No se certifica hardware Android/iPhone.

Se corrigió el servidor de prueba para servir rangos HTTP y esperar la posición real del capítulo; la tolerancia de salto es de tres segundos. También se corrigió la salida del instalador y se verificó una instalación completa y el rechazo de hash incorrecto, versión incorrecta, destino ocupado, rutas externas, archivos no declarados, entradas duplicadas y enlaces simbólicos.

`verify_published.py` comprueba los archivos y reproducción desde el sitio público después del despliegue, sin iniciar sesión ni escribir datos de producción. La comprobación original del runtime de la aplicación se conserva en el flujo de Pages.
