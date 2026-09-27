"""Public Spanish-only user manual. Private translations are not part of this build."""
from pathlib import Path
import html,json,re
R=Path(__file__).resolve().parents[1]
sections=[
('Alcance y reglas esenciales',[
'Pulso organiza una encuesta de salida en Ciudad del Este, Minga Guazú, Hernandarias y Presidente Franco. Las cifras son respuestas de la muestra: no constituyen escrutinio oficial, participación electoral ni pronóstico de ganador.',
'Una instalación corresponde a una empresa y un operativo. Los administradores de esa instalación comparten los datos; no hay aislamiento entre varias empresas dentro de la misma instalación ni un selector de múltiples elecciones.',
'Cada persona usa su cuenta. No se solicita nombre, documento, teléfono, fotografía, comprobante ni ubicación del votante. El GPS opcional corresponde exclusivamente al encuestador.',
'Preparar datos, abrir recepción y autorizar difusión son decisiones separadas. Puede incorporar personal y locales por etapas; no es necesario reunir 60 personas. Los ejemplos del manual son sintéticos y nunca deben registrarse en producción.']),
('Ingresar y reconocer el entorno',[
'Abra la dirección HTTPS entregada por la administración. La ruta /v3/ es el acceso común. En Código o correo ingrese su código individual o correo registrado, escriba Contraseña y pulse Ingresar una vez.',
'La cuenta determina las funciones disponibles. No existe un botón Activate ni un formulario de activación que deba completar la empresa. Un aviso de actualización del servicio se comunica al soporte; no se resuelve creando otra cuenta.',
'DEMOSTRACIÓN o ENSAYO identifica datos de prueba. No confunda estos entornos con el operativo real. El primer ingreso y la asignación inicial necesitan conexión.',
'Use el navegador habitual, no borre los datos del sitio y no cambie de dirección mientras existan pendientes. Salir bloquea el acceso local pero no constituye respaldo. Nunca envíe contraseñas junto con una captura de error.']),
('Cinco áreas de trabajo',[
'Resultados concentra cifras, ciudades, actividad y enlaces de presentación. Locales reúne dirección, puntos, personal y actividad de cada lugar. Equipo reúne Personal, Asignaciones y Cuentas.',
'Registro contiene Todas las respuestas, Revisión y Transcribir papel. Administración contiene Empresa, Candidaturas, Importar, Exportaciones y Jornada. Ayuda está en la parte superior.',
'En computadora use la barra lateral; en teléfono use los botones inferiores. Al entrar a un área, las pestañas superiores permiten cambiar de sección. Los coordinadores solo ven las áreas autorizadas.',
'El encuestador dispone de Encuestar, Pendientes, Mis registros y Ayuda. Mi tarea aparece dentro de Encuestar. El Viewer dispone de Resultados y Ayuda; no recibe formularios de administración.']),
('Filtros de ciudad, local y punto',[
'En Resultados, Locales y Equipo seleccione Todas las ciudades o una ciudad. Luego elija Local de votación y Punto de encuesta. Los filtros se conservan al cambiar entre áreas compatibles.',
'Al cambiar de ciudad se limpian el local, el punto y la persona anteriores; al cambiar de local se limpia el punto. Esto evita mezclar etiquetas de una ciudad con datos de otra.',
'Buscar en Equipo consulta nombre, código o local. En Registro también permite encontrar respuesta, código externo confirmado e identificador. Use Buscar o confirme el cambio del campo. Limpiar filtros vuelve al conjunto permitido.',
'Las pestañas de permisos y la lista de revisión no son una consulta filtrada completa: la revisión muestra páginas recibidas del servidor. Para buscar todas las respuestas del operativo utilice Registro → Todas las respuestas.']),
('Administración: datos de empresa',[
'Abra Administración → Empresa. Complete el nombre de la empresa, su identificación fiscal cuando corresponda, persona de contacto, correo y teléfono de soporte. Guarde mediante el botón del formulario.',
'Para corregir un dato, vuelva a abrir el campo, modifíquelo y guarde. Espere la confirmación del servidor antes de cerrar o pasar el trabajo a otra persona.',
'Si otra persona modificó la misma configuración, recargue y concilie los cambios; no repita a ciegas sobre una versión antigua. El historial de cambios no se borra.',
'Los accesos rápidos llevan a candidaturas, locales, personal, asignaciones y cuentas. Los datos incompletos pueden prepararse sin abrir recepción ni publicar resultados.']),
('Crear y entregar cuentas',[
'Entre en Equipo → Cuentas y pulse Crear acceso. Seleccione el rol permitido: Coordinador, Viewer o Administrador de empresa cuando esa opción esté autorizada para su cuenta.',
'Complete Código único, por ejemplo COORD-001 o VIEW-001, y Nombre de la persona. No use datos ficticios para cuentas operativas ni comparta una identidad entre varias personas.',
'Confirme una vez. La contraseña inicial se genera en el servidor. En Credenciales privadas descargue el TXT y entréguelo únicamente al titular. No publique el archivo en grupos, informes ni repositorios.',
'Cuando el resultado sea incierto, consulte primero la lista. Si la cuenta existe pero se perdió la clave inicial, use el restablecimiento autorizado; no cambie el código para crear un duplicado. Una cuenta administrativa tiene administración global de esta instalación.']),
('Corregir personas, contraseñas y estados',[
'En Equipo → Personal abra Ver persona para corregir Nombre. Se corrige la misma identidad; no se sustituye a una persona por otra. Para un reemplazo incorpore una persona nueva.',
'En Equipo → Cuentas, los botones disponibles permiten corregir el nombre, desactivar, reactivar o restablecer clave según la autorización. No todos los administradores pueden gestionar otras cuentas administrativas.',
'Cambiar rol entre Coordinador y Viewer revoca los alcances previos y exige nuevo ingreso. No convierta la identidad de un encuestador en una cuenta administrativa.',
'Para cambiar su propia contraseña use Mi contraseña o Ayuda → Cambiar mi contraseña; escriba al menos 16 caracteres y repítalos. El restablecimiento de otra cuenta invalida sesiones o autorizaciones anteriores; entregue la nueva clave de forma privada.']),
('Autorizar alcances',[
'En Equipo → Cuentas seleccione Autorizar alcance para un coordinador o Viewer. Defina ciudad, punto cuando corresponda y Válido hasta. El administrador no se limita por esta asignación de ciudad.',
'Para coordinadores autorice solo capacidades necesarias: ver operación, incorporar personal, asignar tareas, crear o aprobar puntos y abrir o pausar puntos. La fecha de vencimiento es obligatoria.',
'Para un Viewer, el alcance permite consultar su ciudad pero no basta por sí solo para divulgar datos: también se requiere habilitación y autorización del informe o canal.',
'Para retirar acceso, revoque el alcance correspondiente. Un dispositivo sin red no recibe la revocación inmediatamente; el servidor vuelve a verificar los envíos cuando se conecta.']),
('Candidaturas: crear, modificar y publicar',[
'Entre en Administración → Candidaturas. Seleccione la ciudad y Nueva versión. Complete cargo, protocolo y la lista real de candidaturas con Nombre y Lista, respetando el orden del catálogo.',
'La pantalla admite de 2 a 12 candidaturas por formulario. Añada o retire filas en el borrador. No utilice códigos externos para preguntar al votante; los nombres reales se conservan en la captura.',
'Guarde el borrador. Revise cargo, ciudad, nombres, listas y orden antes de Publicar formulario verificado. Publicar una nueva versión pausa puntos y tareas de esa ciudad; los responsables deben actualizar y confirmar las nuevas asignaciones.',
'Un formulario publicado no se reescribe para cambiar el pasado. Copie o cree otra versión. Los porcentajes de la portada corresponden a la versión publicada; las versiones anteriores permanecen en Registro.']),
('Crear y modificar locales',[
'En Locales pulse Añadir local. Complete código único, nombre, ciudad y dirección reales. Un local es el establecimiento; el punto identifica el lugar específico de entrevista.',
'Use Editar local para corregir el mismo lugar. Cambiar su nombre no crea un local nuevo ni mueve las entrevistas anteriores. No invente locales oficiales para llenar la pantalla.',
'La tarjeta del local muestra sus puntos, sus tareas y la actividad disponible. El mapa, cuando exista, es una ayuda operativa, no una acreditación oficial de presencia.',
'Los locales sin puntos o personal pueden permanecer en preparación. Falta de cobertura no equivale a cero votos ni representa el total del padrón.']),
('Puntos: aprobar y controlar',[
'Pulse Añadir punto, elija el local y complete un código y una denominación reconocible, por ejemplo Entrada norte. Cada punto pertenece a un solo local y conserva esa relación.',
'Antes de Aprobar punto, verifique el lugar real y el permiso operativo. Puede adjuntar autorización del sitio, metodología o incidente. No adjunte documentos ni fotografías de votantes.',
'Asignar persona abre el formulario de tarea con el punto ya seleccionado. Ver registros lleva a la consulta interna con ese punto. Equipo y detalle del punto despliega las personas y el historial disponible.',
'Abrir punto solo funciona cuando se cumplen las condiciones de fecha, recepción, cuestionario y personal. Pausar punto afecta ese punto; Cerrar punto aparece dentro del detalle. No abre ni cierra otros lugares.']),
('Incorporar un encuestador en el lugar',[
'Entre en Equipo → Personal → Incorporar persona. Seleccione ciudad, punto de incorporación si ya se conoce, y nombre real o denominación reconocible. Puede dejarlo pendiente de asignación.',
'Genere su acceso individual. Entregue el QR o código de una sola persona; no lo publique en grupos. Reemitir reemplaza una invitación anterior que no se completó.',
'La persona se incorpora desde su teléfono, establece la protección local y completa Capacitación breve + práctica. Esta práctica no crea una entrevista ni suma resultados.',
'Después de la práctica y la revisión, el responsable utiliza Aprobar trabajo y asigna una tarea. No marque estos pasos por otra persona ni use un único teléfono o identidad como si fueran 15 encuestadores.']),
('Asignar, cambiar punto o relevar',[
'En Equipo puede pulsar Asignar al lado de la persona. También puede usar Locales → Asignar persona o Equipo → Asignaciones → Nueva asignación. Seleccione persona, punto aprobado y motivo.',
'El encuestador debe confirmar la tarea recibida y comenzar en su dispositivo. Cada identidad mantiene una tarea activa; la hora, el punto y la versión quedan vinculados a sus respuestas.',
'Para cambiar de punto, finalice la tarea anterior permitiendo el envío de pendientes, y cree la nueva. No edite las respuestas guardadas para forzar el punto nuevo.',
'Para reemplazar un dispositivo, preserve y sincronice pendientes antes de revocar. Revocar un dispositivo y finalizar una tarea son operaciones distintas; el historial no se elimina.']),
('Registrar una entrevista',[
'Abra Encuestar y compruebe ciudad, local y punto en la franja de tarea. Si no hay tarea activa, use Mi tarea. No seleccione otra ciudad por iniciativa propia.',
'Confirme que la persona ya votó y que acepta participar de manera anónima y voluntaria. Pulse la candidatura real declarada o una de las opciones en blanco, nulo, no revela o rechazo.',
'Al elegir Rechaza la encuesta, no se guarda candidatura ni se marca consentimiento. Para volver a una candidatura debe comprobar nuevamente la participación voluntaria.',
'Revise el resumen y pulse Guardar encuesta una vez. Primero se guarda cifrada en el teléfono; solo el recibo del servidor confirma recepción. La siguiente entrevista empieza sin la selección y confirmaciones anteriores.',
'Ubicación del encuestador es opcional y está plegada. Obtenga GPS solo al pulsar su botón; sin GPS se conserva el punto asignado. La franja de actividad muestra recibos y pendientes de este archivo local, no el total de todos sus dispositivos.']),
('Pendientes, protección y recuperación',[
'Pendientes muestra los registros del titular en ese teléfono. Pendiente local significa que todavía no hay confirmación central; no aumenta automáticamente la estadística del servidor.',
'Use Sincronizar ahora al recuperar Internet. Reenviar una respuesta con el mismo identificador no duplica el conteo; cambiar el contenido de un identificador existente es rechazado.',
'Guarde la frase de protección local: tiene al menos 12 caracteres y no es la contraseña de acceso. No existe recuperación automática de una frase olvidada.',
'Guardar copia cifrada permite rescatar el archivo propio. Recuperar copia propia exige la misma identidad y la frase correspondiente; comprueba recibos antes de reenviar. No borre el navegador para resolver un error.',
'Si una tarea anterior necesita recuperación de envío, use la opción específica ofrecida. Esos registros pueden quedar en revisión; no se cuentan automáticamente por el solo hecho de recuperar el archivo.']),
('Jornada y apertura de recepción',[
'Abra Administración → Jornada para título, cargo, Fecha electoral, renovación de tareas, recepción de pendientes y política de conservación. Guarde la configuración y revise su lectura posterior.',
'Iniciar / reanudar operación controla la recepción global y requiere la fecha y condiciones del servidor. Después abra cada punto listo. No existe una activación adicional de versión.',
'Pausar toda la operación afecta nuevas capturas globalmente. Cerrar operación conserva los tratamientos permitidos de pendientes; no borra el historial.',
'No cambie la fecha real para practicar y no pruebe votos en producción. Use únicamente el entorno de ensayo autorizado.'],),
('Registro completo y revisión',[
'Entre en Registro → Todas las respuestas. El sistema obtiene una instantánea completa antes de mostrarla, con corte, total y coincidencias. La tabla presenta 50 filas por página; la paginación no limita el alcance de búsqueda.',
'Filtre ciudad, local, punto, persona, estado o texto. Desde y Hasta se refieren a recepción del servidor en UTC−3; el último minuto seleccionado se incluye. Actualizar registros crea una nueva instantánea.',
'Los nombres de personas y locales se resuelven con el directorio actual; se conserva cada identificador original. La candidatura se resuelve según la versión de la respuesta. El código externo solo se muestra si está confirmado al consultar.',
'Ver detalle muestra horas, origen, estado e identificadores de auditoría. Para resolver pendientes, use la pestaña Revisión y documente la decisión; no elimine filas para cuadrar cifras. Revisión muestra páginas del servidor y no reutiliza todos los filtros de la instantánea.']),
('Papel e importación R3',[
'En Registro → Transcribir papel identifique la hoja, persona, punto, versión, horas y respuesta. El registro transcrito requiere revisión independiente antes de sumarse como aceptado.',
'Administración → Importar permite descargar la plantilla R3, elegir tipo y cargar CSV o XLSX. Se admiten hasta 1.000 filas por lote. No incluya fórmulas, macros, vínculos externos ni contraseñas.',
'Pulse Revisar archivo y examine los errores antes de Confirmar carga de este lote. Una vista previa no aplica datos; una carga confirmada no publica formularios ni abre puntos.',
'Importe primero los registros completos que ya conoce. Los registros existentes no se sobrescriben automáticamente; corrija datos existentes mediante sus formularios.']),
('Interpretar Resultados',[
'La portada muestra Contactos recibidos, Base de candidaturas, Personas en servicio y Por revisar. Recibido no es igual a aceptado: las exclusiones y revisiones se mantienen para auditoría.',
'Cada ciudad usa su propia base y el formulario publicado. Porcentaje = respuestas de una candidatura / base de candidaturas de esa ciudad o selección de puntos. No se mezclan versiones anteriores.',
'Ejemplo sintético: A=2, B=1, blanco=1 y rechazo=1 producen 5 contactos y base=3. Las proporciones de A y B son 66,7 % y 33,3 %, no 40 % y 20 %. Redondeos pueden impedir que la suma visual sea exactamente 100 %.',
'En la vista completa de ciudad, blancos, nulos, no revela y rechazos se muestran aparte. El agregado actual por punto no incluye ese desglose: se indica la limitación y se consulta Registro, sin inventar ceros.',
'Actividad por hora representa contactos según hora declarada del teléfono, no evolución de apoyo. Personas en servicio se basa en tareas activas, no prueba presencia. Los pendientes reportados pueden ser desconocidos cuando falta señal.']),
('Informes internos y códigos externos',[
'En Resultados abra Informes por códigos. El control permite revisar nombres reales, Lista y códigos privados por ciudad y versión. El mapa no se entrega a Viewers ni se adjunta a informes externos.',
'Confirme los códigos después de verificarlos. La encuesta sigue preguntando nombres reales; el informe externo usa solamente códigos. No use un apodo que permita confundir la identidad interna.',
'Cree el corte de informe y compare base, totales y hora. Las versiones interna y externa corresponden al mismo corte. El registro completo de trabajo y el mapa vigente no sustituyen este corte histórico.',
'Descargue el archivo interno solo para responsables autorizados. El externo se produce a partir de datos limitados, no ocultando nombres con estilos. Un borrador o una muestra insuficiente no autoriza difusión.']),
('Pantalla en vivo y presentación',[
'En Resultados pulse Pantalla en vivo para abrir el monitor interno. El monitor permite una ciudad o las cuatro, ajustándose a teléfono, tableta, computadora o pantalla grande.',
'El monitor consulta periódicamente mientras continúa la encuesta; no necesita esperar el cierre. Actualizar fuerza una consulta, Pausar congela la pantalla y Rotación alterna ciudades permitidas.',
'En la portada, Pausar actualización tampoco detiene encuestadores ni recepción. Al abandonar esa vista se reanuda su actualización. Mantenga visible la hora del último dato confirmado.',
'El enlace abierto desde un local o punto es En vivo · ciudad completa: el monitor externo a la portada trabaja por ciudad, no hereda silenciosamente un filtro de punto.',
'PNG, CSV y PDF/HTML son archivos del instante de exportación. No se actualizan después de descargarse. Pantalla completa depende del navegador; no equivale a autorización para mostrar nombres internos al público.']),
('Viewer y difusión autorizada',[
'Un Viewer solo obtiene ciudades y canales expresamente habilitados. Primero asigne su alcance y vencimiento; después configure la publicación en el control de informes o canal.',
'Acceso a resultados pendiente significa que no existe autorización suficiente; no solucione esto entregando una cuenta administrativa.',
'Los canales externos usan códigos y aplican restricciones de autorización, vigencia y tamaños pequeños. Retirar autorización corta el acceso en la próxima comprobación; una copia previamente descargada no puede retirarse remotamente.',
'La empresa verifica las restricciones aplicables antes de difundir resultados. Un botón disponible, un código o una pantalla de demostración no concede permiso legal ni convierte la muestra en escrutinio oficial.']),
('Exportar, conciliar y cerrar',[
'Registro → Exportar selección genera todas las coincidencias de la instantánea cargada, no solo las 50 filas visibles. El archivo está marcado USO INTERNO, incluye corte y conserva identificadores.',
'Administración → Exportaciones ofrece instantáneas de datos y auditoría según el tipo elegido. El servidor admite hasta 100.000 filas por exportación; si rechaza el límite, no se presenta un archivo parcial como completo.',
'Conciliación: compare contactos, estado, versión y base antes de comparar porcentajes. Los lotes sin red pueden recibirse después; use las dos horas para explicar la diferencia.',
'Al terminar, conserve las exportaciones necesarias en almacenamiento autorizado, cierre recepción según protocolo y revise los pendientes. No borre usuarios o respuestas para preparar otra elección.']),
('Prueba operativa breve',[
'Use una copia de ensayo ya autorizada, sin crear costos ni nuevos recursos desde el App. Prepare un punto y una persona; no hace falta completar cuatro ciudades o 60 cuentas para ensayar.',
'Compruebe ingreso individual, práctica, aprobación, tarea, ciudad y candidaturas. Envíe una respuesta sintética; observe su recibo y que otra pantalla del mismo ensayo aumente sin recargar.',
'Haga una prueba de guardar sin conexión, reconectar y reenviar. El servidor debe contar una sola vez. Compruebe teclado, mensajes, rotación del teléfono y que los botones inferiores no tapen Guardar.',
'La aprobación de pruebas se registra según lo realmente observado. Una prueba automatizada, una pantalla de demostración o almacenamiento temporal exitoso no certifican teléfonos físicos ni toda la jornada.']),
('Resolver problemas sin perder datos',[
'No se puede ingresar: revise código, contraseña y mensaje visible. Evite repetir muchos intentos; entregue al soporte la referencia del error, no su contraseña.',
'No aparece una candidatura: confirme ciudad, tarea y versión publicada. No escriba la respuesta en otra candidatura ni cambie el punto para forzar el envío.',
'La pantalla no actualiza: compruebe si está pausada, la conexión y la última hora confirmada. Actualización sin confirmar mantiene la consulta anterior, no demuestra que no hayan llegado entrevistas.',
'Falla de almacenamiento: use el diagnóstico por etapas. Distingue apertura, esquema, escritura, lectura, cierre y limpieza de la base temporal. No borra la base de entrevistas y no repara pendientes eliminándolos.',
'Conflicto de edición: recargue el registro y revise lo cambiado por otro responsable. Cuenta creada sin clave disponible: confirme que existe y restablezca el acceso autorizado. No cree duplicados.']),
('Cambios permitidos y límites',[
'Puede corregir datos de la misma empresa, persona o local. Los códigos de identidad y el historial se conservan. Un reemplazo de persona o lugar distinto exige un registro nuevo.',
'Cambiar asignación crea otra tarea; cambiar candidaturas publicadas exige otra versión. Aceptar o excluir una respuesta cambia su tratamiento, no inventa un voto ni elimina el registro original.',
'La simplificación visual no amplía los permisos. Las cuentas solo reciben los datos y operaciones autorizados por el servidor, aunque alguien intente abrir otra dirección manualmente.',
'La documentación bilingüe y la administración técnica se entregan por un canal separado al responsable. El sitio de trabajo y este manual público permanecen completamente en español.'])
]
assert len(sections)==26
css='''*{box-sizing:border-box}body{margin:0;font:18px/1.7 system-ui,Arial,sans-serif;color:#17343d;background:#f3f6f7}header{background:#113740;color:white;padding:40px max(22px,calc((100vw - 1040px)/2))}h1{font-size:clamp(30px,5vw,44px);line-height:1.2}header small{letter-spacing:3px}main{max-width:1040px;margin:auto;padding:26px}section,nav{background:white;border:1px solid #dbe5e7;border-radius:14px;padding:28px;margin-bottom:22px}h2{font-size:26px;line-height:1.3;color:#165f63}p{overflow-wrap:anywhere}nav a{display:block;padding:6px 0}a{color:#126d70}li{margin:13px 0}.note{background:#e6f1ec;padding:18px;border-radius:10px}@media(max-width:600px){main{padding:14px}section,nav{padding:20px}body{font-size:17px}h2{font-size:23px}}@media print{body{background:white;font-size:10.5pt}header{background:white;color:#17343d;padding:0}main{padding:0}section{border:0;padding:12px 0}h2{break-after:avoid;font-size:18pt}li{break-inside:avoid}nav{break-after:page}}'''
toc=''.join(f'<a href="#s{i:02d}">{i:02d} · {html.escape(title)}</a>' for i,(title,_) in enumerate(sections,1))
body=''.join(f'<section id="s{i:02d}"><h2>{i:02d} · {html.escape(title)}</h2><ol>'+''.join('<li>'+html.escape(x)+'</li>' for x in blocks)+'</ol><a href="#indice">Volver al índice</a></section>' for i,(title,blocks) in enumerate(sections,1))
page='<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Pulso · Manual de uso 3.1.3</title><style>'+css+'</style></head><body><header><small>PULSO · MANUAL 3.1.3</small><h1>Administrar, encuestar y verificar</h1><p>Resultados · Locales · Equipo · Registro · Administración</p></header><main><section><p class="note">Edición 27 septiembre 2026. Interfaz simplificada sobre las mismas reglas de datos y permisos. No se necesita reinstalar la base para este cambio visual.</p></section><nav id="indice"><h2>Índice</h2>'+toc+'</nav>'+body+'</main></body></html>'
assert not re.search('[\u3400-\u9fff]|Super Admin|jaimehuang168@gmail',page)
(R/'v3/web/manual-es.html').write_text(page)
(R/'v3/web/manual-es-zh.html').unlink(missing_ok=True)
print(json.dumps({'public_language':'es','chapters':len(sections),'paragraphs':sum(len(x[1]) for x in sections),'private_manual_published':False}))
