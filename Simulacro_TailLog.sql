-- Simulacro de falla con respaldo de cola del log (tail-log)
-- GimnasioDB_Restore hace de servidor que se cae y se recupera en GimnasioDB_Lab
-- La base GimnasioDB no se toca

USE master;
GO

-- 1. Limpieza de una corrida anterior
IF DB_ID('GimnasioDB_Lab') IS NOT NULL
BEGIN
    ALTER DATABASE GimnasioDB_Lab SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE GimnasioDB_Lab;
END
GO

IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'GimnasioDB_Restore' AND state_desc = 'RESTORING')
    RESTORE DATABASE GimnasioDB_Restore WITH RECOVERY;
GO

ALTER DATABASE GimnasioDB_Restore SET MULTI_USER;
ALTER DATABASE GimnasioDB_Restore SET RECOVERY FULL;
GO

-- Borra los pagos de prueba de una corrida anterior
DELETE FROM GimnasioDB_Restore.facturacion.Pagos
WHERE SocioID = 1 AND Monto IN (11.11, 22.22);
GO

-- 2. Backup FULL de la base origen
BACKUP DATABASE GimnasioDB_Restore
TO DISK = N'/backup/Simulacro_FULL.bak'
WITH INIT, NAME = N'Simulacro - FULL';
GO

-- 3. Se registra un pago y se respalda el log
INSERT INTO GimnasioDB_Restore.facturacion.Pagos (SocioID, MembresiaID, Monto, MetodoPago)
VALUES (1, 1, 11.11, 'Efectivo');

BACKUP LOG GimnasioDB_Restore
TO DISK = N'/backup/Simulacro_LOG.trn'
WITH INIT, NAME = N'Simulacro - LOG';
GO

-- 4. Se registra otro pago que ya no alcanza a quedar en ningún backup
INSERT INTO GimnasioDB_Restore.facturacion.Pagos (SocioID, MembresiaID, Monto, MetodoPago)
VALUES (1, 1, 22.22, 'Tarjeta');
GO

-- 5. Falla: se toma la cola del log. NORECOVERY deja la base origen en estado RESTORING
-- Primero se cierran las conexiones abiertas a la base, porque NORECOVERY necesita acceso exclusivo
ALTER DATABASE GimnasioDB_Restore SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
BACKUP LOG GimnasioDB_Restore
TO DISK = N'/backup/Simulacro_TAIL.trn'
WITH INIT, NORECOVERY, NAME = N'Simulacro - TAIL-LOG';
GO

SELECT name AS BaseDeDatos, state_desc AS Estado
FROM sys.databases
WHERE name IN ('GimnasioDB', 'GimnasioDB_Restore');
GO

-- 6. Recuperación en GimnasioDB_Lab: FULL, LOG, tail-log y RECOVERY
DECLARE @inicio DATETIME2 = SYSDATETIME();

RESTORE DATABASE GimnasioDB_Lab FROM DISK = N'/backup/Simulacro_FULL.bak'
WITH MOVE 'GimnasioDB_Primary' TO '/var/opt/mssql/data/GimnasioDB_Lab.mdf',
     MOVE 'GimnasioDB_Datos'   TO '/var/opt/mssql/data/GimnasioDB_Lab_Datos.ndf',
     MOVE 'GimnasioDB_Indices' TO '/var/opt/mssql/data/GimnasioDB_Lab_Indices.ndf',
     MOVE 'GimnasioDB_Log'     TO '/var/opt/mssql/data/GimnasioDB_Lab_Log.ldf',
     NORECOVERY;

RESTORE LOG GimnasioDB_Lab FROM DISK = N'/backup/Simulacro_LOG.trn'  WITH NORECOVERY;
RESTORE LOG GimnasioDB_Lab FROM DISK = N'/backup/Simulacro_TAIL.trn' WITH NORECOVERY;
RESTORE DATABASE GimnasioDB_Lab WITH RECOVERY;

SELECT CAST(DATEDIFF(MILLISECOND, @inicio, SYSDATETIME()) / 1000.0 AS DECIMAL(10,2)) AS TiempoRecuperacionSegundos;
GO

-- 7. Verificación: deben aparecer los dos pagos, incluido el que no estaba en ningún backup
SELECT PagoID, SocioID, Monto, MetodoPago, FechaPago
FROM GimnasioDB_Lab.facturacion.Pagos
WHERE Monto IN (11.11, 22.22)
ORDER BY PagoID;
GO

-- Integridad de la base recuperada
DBCC CHECKDB ('GimnasioDB_Lab') WITH NO_INFOMSGS;
SELECT 'DBCC CHECKDB terminado' AS Resultado;
GO

-- 8. Se devuelve GimnasioDB_Restore a línea y se vuelve a permitir varias conexiones
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'GimnasioDB_Restore' AND state_desc = 'RESTORING')
    RESTORE DATABASE GimnasioDB_Restore WITH RECOVERY;
GO

ALTER DATABASE GimnasioDB_Restore SET MULTI_USER;
ALTER DATABASE GimnasioDB_Lab SET MULTI_USER;
GO

SELECT name AS BaseDeDatos, state_desc AS Estado
FROM sys.databases
WHERE name IN ('GimnasioDB', 'GimnasioDB_Restore', 'GimnasioDB_Lab');
GO
