/** Read-only installation status. No company activation or attestation form. */
import {esc as E} from './core.mjs';
export const isCompanyAdmin=b=>b?.actor?.role==='admin'&&b.actor.is_super_admin===false;
export function readinessCard(S){
 const b=S.boot,d=S.readiness,owner=b?.actor?.is_super_admin===true;
 if(b?.actor?.role!=='admin')return '';
 const live=b.operation_mode==='v3';
 const known=d?.module_014_installed===true;
 const state=live?'Acceso directo V3.1':'Configuración disponible · actualización técnica pendiente';
 const intro=live?'Ingrese con su cuenta y utilice las funciones de su rol. No hay un paso de activación.':'Puede preparar datos y usuarios. Solo el Super Admin completa la actualización técnica; la empresa no ejecuta SQL ni confirma una activación.';
 const modules=owner?`<p>Módulo 013: ${known?(d.module_013_installed?'instalado':'no confirmado'):'sin verificar en esta sesión'} · Acceso directo: ${known?'instalado':'sin verificar en esta sesión'}</p>`:'';
 return `<section class="card" data-company-readiness><h2>Uso de la aplicación</h2><p class="badge">${state}</p><p>${intro}</p>${modules}${S.readinessError&&owner?`<p class="inline-note">${E(S.readinessError)}</p>`:''}<p>La fecha, la apertura de cada punto y la difusión conservan sus controles. No se crean respuestas ni autorizaciones automáticamente.</p><button type="button" data-action="readiness-refresh">Actualizar estado</button></section>`;
}
