-- ------------------------------------------------------------------------
-- PARTE 1 - Integrante 1
-- Arquitectura física, esquemas, seguridad y auditoría
-- ------------------------------------------------------------------------

-- 1. Limpieza: borra la base, la auditoría y los logins si ya existen
USE master;
GO

IF DB_ID('GimnasioDB') IS NOT NULL
BEGIN
    ALTER DATABASE GimnasioDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE GimnasioDB;
END
GO

IF EXISTS (SELECT 1 FROM sys.server_audit_specifications WHERE name = 'AuditSpec_Servidor_Gimnasio')
BEGIN
    ALTER SERVER AUDIT SPECIFICATION AuditSpec_Servidor_Gimnasio WITH (STATE = OFF);
    DROP SERVER AUDIT SPECIFICATION AuditSpec_Servidor_Gimnasio;
END
GO

IF EXISTS (SELECT 1 FROM sys.server_audits WHERE name = 'Audit_GimnasioDB')
BEGIN
    ALTER SERVER AUDIT Audit_GimnasioDB WITH (STATE = OFF);
    DROP SERVER AUDIT Audit_GimnasioDB;
END
GO

-- Borra los jobs antes que los logins, porque su dueño es login_respaldo
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'GimnasioDB - Backup FULL')
    EXEC msdb.dbo.sp_delete_job @job_name = N'GimnasioDB - Backup FULL', @delete_unused_schedule = 1;
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'GimnasioDB - Backup DIFERENCIAL')
    EXEC msdb.dbo.sp_delete_job @job_name = N'GimnasioDB - Backup DIFERENCIAL', @delete_unused_schedule = 1;
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'GimnasioDB - Backup LOG')
    EXEC msdb.dbo.sp_delete_job @job_name = N'GimnasioDB - Backup LOG', @delete_unused_schedule = 1;

IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'login_recepcion')
    DROP LOGIN login_recepcion;
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'login_facturacion')
    DROP LOGIN login_facturacion;
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'login_powerbi')
    DROP LOGIN login_powerbi;
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'login_respaldo')
    DROP LOGIN login_respaldo;
GO

-- 2. Logins de recepción, facturación, Power BI y respaldos
CREATE LOGIN login_recepcion
    WITH PASSWORD = 'PasswordRec#2026',
    CHECK_POLICY = ON,
    CHECK_EXPIRATION = OFF;

CREATE LOGIN login_facturacion
    WITH PASSWORD = 'PasswordFact#2026',
    CHECK_POLICY = ON,
    CHECK_EXPIRATION = OFF;

CREATE LOGIN login_powerbi
    WITH PASSWORD = 'PasswordBI#2026',
    CHECK_POLICY = ON,
    CHECK_EXPIRATION = OFF;

-- Login solo para los backups
CREATE LOGIN login_respaldo
    WITH PASSWORD = 'PasswordResp#2026',
    CHECK_POLICY = ON,
    CHECK_EXPIRATION = OFF;
GO

-- 3. Base de datos con filegroups: FG_Datos para las tablas y FG_Indices para los índices
DECLARE @data NVARCHAR(400) = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS NVARCHAR(400));
DECLARE @log  NVARCHAR(400) = CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS NVARCHAR(400));

DECLARE @sql NVARCHAR(MAX) = N'
CREATE DATABASE GimnasioDB
ON PRIMARY
    (NAME = GimnasioDB_Primary, FILENAME = ''' + @data + N'GimnasioDB.mdf'', SIZE = 16MB, FILEGROWTH = 16MB),
FILEGROUP FG_Datos
    (NAME = GimnasioDB_Datos, FILENAME = ''' + @data + N'GimnasioDB_Datos.ndf'', SIZE = 128MB, FILEGROWTH = 64MB),
FILEGROUP FG_Indices
    (NAME = GimnasioDB_Indices, FILENAME = ''' + @data + N'GimnasioDB_Indices.ndf'', SIZE = 64MB, FILEGROWTH = 32MB)
LOG ON
    (NAME = GimnasioDB_Log, FILENAME = ''' + @log + N'GimnasioDB_Log.ldf'', SIZE = 64MB, FILEGROWTH = 64MB);';
EXEC (@sql);
GO

USE GimnasioDB;
GO

-- FG_Datos queda como filegroup por defecto y la base en modelo de recuperación FULL
ALTER DATABASE GimnasioDB MODIFY FILEGROUP FG_Datos DEFAULT;

ALTER DATABASE GimnasioDB SET RECOVERY FULL;
GO

-- 4. Esquemas por área del gimnasio
CREATE SCHEMA socios;
GO
CREATE SCHEMA operaciones;
GO
CREATE SCHEMA facturacion;
GO
CREATE SCHEMA seguridad;
GO
CREATE SCHEMA reportes;
GO

-- 5. Tablas con sus llaves y restricciones
CREATE TABLE socios.Socios (
    SocioID INT IDENTITY(1,1) NOT NULL,
    Nombre VARCHAR(60) NOT NULL,
    Apellido VARCHAR(60) NOT NULL,
    DUI VARCHAR(10) NOT NULL,
    Telefono VARCHAR(15) NULL,
    Email VARCHAR(100) NOT NULL,
    FechaRegistro DATE NOT NULL CONSTRAINT DF_Socios_Fecha DEFAULT (CAST(GETDATE() AS DATE)),
    Estado VARCHAR(15) NOT NULL CONSTRAINT DF_Socios_Estado DEFAULT 'Activo',
    CONSTRAINT PK_Socios PRIMARY KEY CLUSTERED (SocioID),
    CONSTRAINT UQ_Socios_DUI UNIQUE (DUI),
    CONSTRAINT UQ_Socios_Email UNIQUE (Email),
    CONSTRAINT CHK_Socios_Estado CHECK (Estado IN ('Activo', 'Inactivo', 'Suspendido'))
);
GO

CREATE TABLE operaciones.Entrenadores (
    EntrenadorID INT IDENTITY(1,1) NOT NULL,
    NombreCompleto VARCHAR(100) NOT NULL,
    Especialidad VARCHAR(50) NOT NULL,
    CONSTRAINT PK_Entrenadores PRIMARY KEY CLUSTERED (EntrenadorID),
    CONSTRAINT CHK_Entrenadores_Esp CHECK (Especialidad IN ('Crossfit', 'Pesas', 'Yoga', 'Spinning', 'Box'))
);
GO

CREATE TABLE operaciones.Clases (
    ClaseID INT IDENTITY(1,1) NOT NULL,
    NombreClase VARCHAR(50) NOT NULL,
    EntrenadorID INT NOT NULL,
    CupoMaximo INT NOT NULL,
    Horario DATETIME2 NOT NULL,
    CONSTRAINT PK_Clases PRIMARY KEY CLUSTERED (ClaseID),
    CONSTRAINT FK_Clases_Entrenador FOREIGN KEY (EntrenadorID)
        REFERENCES operaciones.Entrenadores (EntrenadorID),
    CONSTRAINT CHK_Clases_Cupo CHECK (CupoMaximo > 0 AND CupoMaximo <= 40)
);
GO

CREATE TABLE operaciones.Reservas (
    ReservaID INT IDENTITY(1,1) NOT NULL,
    SocioID INT NOT NULL,
    ClaseID INT NOT NULL,
    FechaReserva DATETIME2 NOT NULL CONSTRAINT DF_Reservas_Fecha DEFAULT SYSDATETIME(),
    Asistencia BIT NOT NULL CONSTRAINT DF_Reservas_Asistencia DEFAULT 0,
    CONSTRAINT PK_Reservas PRIMARY KEY CLUSTERED (ReservaID),
    CONSTRAINT FK_Reservas_Socio FOREIGN KEY (SocioID)
        REFERENCES socios.Socios (SocioID),
    CONSTRAINT FK_Reservas_Clase FOREIGN KEY (ClaseID)
        REFERENCES operaciones.Clases (ClaseID),
    CONSTRAINT UQ_Reservas_Socio_Clase UNIQUE (SocioID, ClaseID)
);
GO

-- Trigger que no deja pasar el cupo máximo de una clase
CREATE OR ALTER TRIGGER operaciones.TR_Reservas_ValidarCupo
ON operaciones.Reservas
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (
        SELECT 1
        FROM operaciones.Clases c
        WHERE c.ClaseID IN (SELECT ClaseID FROM inserted)
          AND (SELECT COUNT(*) FROM operaciones.Reservas r WHERE r.ClaseID = c.ClaseID) > c.CupoMaximo
    )
    BEGIN
        THROW 50001, 'La clase ya alcanzo su cupo maximo de capacidad.', 1;
    END
END;
GO

CREATE TABLE facturacion.Membresias (
    MembresiaID INT IDENTITY(1,1) NOT NULL,
    TipoMembresia VARCHAR(30) NOT NULL,
    DuracionDias INT NOT NULL,
    Costo DECIMAL(10,2) NOT NULL,
    CONSTRAINT PK_Membresias PRIMARY KEY CLUSTERED (MembresiaID),
    CONSTRAINT CHK_Membresias_Tipo CHECK (TipoMembresia IN ('Mensual', 'Trimestral', 'Anual', 'VIP')),
    CONSTRAINT CHK_Membresias_Duracion CHECK (DuracionDias > 0),
    CONSTRAINT CHK_Membresias_Costo CHECK (Costo > 0)
);
GO

CREATE TABLE facturacion.Pagos (
    PagoID INT IDENTITY(1,1) NOT NULL,
    SocioID INT NOT NULL,
    MembresiaID INT NOT NULL,
    Monto DECIMAL(10,2) NOT NULL,
    MetodoPago VARCHAR(20) NOT NULL,
    FechaPago DATETIME2 NOT NULL CONSTRAINT DF_Pagos_Fecha DEFAULT SYSDATETIME(),
    CONSTRAINT PK_Pagos PRIMARY KEY CLUSTERED (PagoID),
    CONSTRAINT FK_Pagos_Socio FOREIGN KEY (SocioID)
        REFERENCES socios.Socios (SocioID),
    CONSTRAINT FK_Pagos_Membresia FOREIGN KEY (MembresiaID)
        REFERENCES facturacion.Membresias (MembresiaID),
    CONSTRAINT CHK_Pagos_Monto CHECK (Monto > 0),
    CONSTRAINT CHK_Pagos_Metodo CHECK (MetodoPago IN ('Efectivo', 'Tarjeta', 'Transferencia'))
);
GO

-- 6. Bitácora de pagos: tabla AuditoriaLog y trigger que registra cada pago insertado o borrado
CREATE TABLE seguridad.AuditoriaLog (
    LogID INT IDENTITY(1,1) NOT NULL,
    Usuario VARCHAR(128) NOT NULL,
    FechaHora DATETIME2 NOT NULL CONSTRAINT DF_Auditoria_Fecha DEFAULT SYSDATETIME(),
    Accion VARCHAR(50) NOT NULL,
    Detalle NVARCHAR(MAX) NOT NULL,
    CONSTRAINT PK_Auditoria PRIMARY KEY CLUSTERED (LogID)
);
GO

CREATE OR ALTER TRIGGER facturacion.TR_Audit_Pagos
ON facturacion.Pagos
AFTER INSERT, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted)
    BEGIN
        INSERT INTO seguridad.AuditoriaLog (Usuario, Accion, Detalle)
        SELECT SUSER_SNAME(), 'INSERT PAGO',
               CONCAT('Pago insertado. ID: ', PagoID, ', Socio: ', SocioID, ', Monto: $', Monto)
        FROM inserted;
    END

    IF EXISTS (SELECT 1 FROM deleted)
    BEGIN
        INSERT INTO seguridad.AuditoriaLog (Usuario, Accion, Detalle)
        SELECT SUSER_SNAME(), 'DELETE PAGO (ALERTA)',
               CONCAT('Intento/borrado de pago. ID: ', PagoID, ', Monto: $', Monto)
        FROM deleted;
    END
END;
GO

-- 7. Procedimientos almacenados
CREATE OR ALTER PROCEDURE socios.sp_ConsultarSocioPorDUI
    @DUI VARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT SocioID, Nombre, Apellido, Telefono, Estado
    FROM socios.Socios
    WHERE DUI = @DUI;
END;
GO

CREATE OR ALTER PROCEDURE facturacion.sp_RegistrarPago
    @SocioID INT,
    @MembresiaID INT,
    @Monto DECIMAL(10,2),
    @MetodoPago VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO facturacion.Pagos (SocioID, MembresiaID, Monto, MetodoPago)
    VALUES (@SocioID, @MembresiaID, @Monto, @MetodoPago);
END;
GO

CREATE OR ALTER PROCEDURE operaciones.sp_ConsultarClasesDisponibles
AS
BEGIN
    SET NOCOUNT ON;
    SELECT c.ClaseID, c.NombreClase, e.NombreCompleto AS Entrenador, c.CupoMaximo, c.Horario,
           (c.CupoMaximo - COUNT(r.ReservaID)) AS CuposRestantes
    FROM operaciones.Clases c
    INNER JOIN operaciones.Entrenadores e ON c.EntrenadorID = e.EntrenadorID
    LEFT JOIN operaciones.Reservas r ON c.ClaseID = r.ClaseID
    GROUP BY c.ClaseID, c.NombreClase, e.NombreCompleto, c.CupoMaximo, c.Horario;
END;
GO

-- Vistas para Power BI, sin datos personales de los socios
CREATE OR ALTER VIEW reportes.vw_Socios AS
SELECT SocioID, FechaRegistro, Estado
FROM socios.Socios;
GO

CREATE OR ALTER VIEW reportes.vw_Pagos AS
SELECT p.PagoID, p.SocioID, m.TipoMembresia, p.Monto, p.MetodoPago, p.FechaPago,
       DATEADD(DAY, m.DuracionDias, p.FechaPago) AS FechaVencimiento
FROM facturacion.Pagos p
INNER JOIN facturacion.Membresias m ON p.MembresiaID = m.MembresiaID;
GO

CREATE OR ALTER VIEW reportes.vw_Reservas AS
SELECT r.ReservaID, r.SocioID, c.ClaseID, c.NombreClase,
       e.NombreCompleto AS Entrenador, e.Especialidad, c.Horario, r.FechaReserva, r.Asistencia
FROM operaciones.Reservas r
INNER JOIN operaciones.Clases c ON r.ClaseID = c.ClaseID
INNER JOIN operaciones.Entrenadores e ON c.EntrenadorID = e.EntrenadorID;
GO

-- 8. Usuarios y roles
CREATE USER usr_recepcion FOR LOGIN login_recepcion;
CREATE USER usr_facturacion FOR LOGIN login_facturacion;
CREATE USER usr_powerbi FOR LOGIN login_powerbi;
CREATE USER usr_respaldo FOR LOGIN login_respaldo;
GO

CREATE ROLE rol_recepcion;
CREATE ROLE rol_cajero;
CREATE ROLE rol_reporteria;
GO

-- Recepción: consulta y modifica socios y operaciones, pero no puede borrar
GRANT SELECT, INSERT, UPDATE ON SCHEMA::socios TO rol_recepcion;
GRANT SELECT, INSERT, UPDATE ON SCHEMA::operaciones TO rol_recepcion;
GRANT EXECUTE ON SCHEMA::operaciones TO rol_recepcion;
DENY DELETE ON SCHEMA::socios TO rol_recepcion;
DENY DELETE ON SCHEMA::operaciones TO rol_recepcion;

-- Cajero: registra pagos y busca socios por DUI, pero no puede modificar ni borrar pagos
GRANT EXECUTE ON OBJECT::socios.sp_ConsultarSocioPorDUI TO rol_cajero;
GRANT SELECT, INSERT ON SCHEMA::facturacion TO rol_cajero;
GRANT EXECUTE ON SCHEMA::facturacion TO rol_cajero;
DENY UPDATE, DELETE ON SCHEMA::facturacion TO rol_cajero;

-- Power BI: solo lectura sobre el esquema reportes
GRANT SELECT ON SCHEMA::reportes TO rol_reporteria;
GO

-- Cada usuario se agrega a su rol
ALTER ROLE rol_recepcion ADD MEMBER usr_recepcion;
ALTER ROLE rol_cajero ADD MEMBER usr_facturacion;
ALTER ROLE rol_reporteria ADD MEMBER usr_powerbi;

-- usr_respaldo solo puede hacer backups (rol fijo db_backupoperator)
ALTER ROLE db_backupoperator ADD MEMBER usr_respaldo;
GO

-- 9. Auditoría con SQL Server Audit (archivos .sqlaudit en la carpeta SQLAudit de la instancia)
USE master;
GO

DECLARE @dataPath NVARCHAR(400) = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS NVARCHAR(400));
DECLARE @auditPath NVARCHAR(500) = @dataPath + N'SQLAudit\';

EXEC master.dbo.xp_create_subdir @auditPath;

DECLARE @sqlAudit NVARCHAR(MAX) = N'
CREATE SERVER AUDIT Audit_GimnasioDB
TO FILE (FILEPATH = ''' + @auditPath + N''', MAXSIZE = 50 MB, MAX_ROLLOVER_FILES = 10)
WITH (ON_FAILURE = CONTINUE);';
EXEC (@sqlAudit);
GO

ALTER SERVER AUDIT Audit_GimnasioDB WITH (STATE = ON);
GO

-- Nivel servidor: logins fallidos, cambios de logins, backups y restauraciones
CREATE SERVER AUDIT SPECIFICATION AuditSpec_Servidor_Gimnasio
FOR SERVER AUDIT Audit_GimnasioDB
ADD (FAILED_LOGIN_GROUP),
ADD (SERVER_PRINCIPAL_CHANGE_GROUP),
ADD (BACKUP_RESTORE_GROUP)
WITH (STATE = ON);
GO

-- Nivel base de datos: cambios en facturacion y socios, lecturas de Socios y cambios de permisos o roles
USE GimnasioDB;
GO

CREATE DATABASE AUDIT SPECIFICATION AuditSpec_GimnasioDB
FOR SERVER AUDIT Audit_GimnasioDB
ADD (INSERT, UPDATE, DELETE ON SCHEMA::facturacion BY public),
ADD (UPDATE, DELETE ON SCHEMA::socios BY public),
ADD (SELECT ON OBJECT::socios.Socios BY public),
ADD (DATABASE_PERMISSION_CHANGE_GROUP),
ADD (SCHEMA_OBJECT_PERMISSION_CHANGE_GROUP),
ADD (DATABASE_ROLE_MEMBER_CHANGE_GROUP)
WITH (STATE = ON);
GO

-- 10. Consulta de los logs de auditoría (event_time está en hora UTC)
DECLARE @ruta NVARCHAR(500) =
    (SELECT log_file_path FROM sys.server_file_audits WHERE name = 'Audit_GimnasioDB') + N'*.sqlaudit';

SELECT event_time, action_id, succeeded, server_principal_name,
       database_principal_name, schema_name, object_name, statement
FROM sys.fn_get_audit_file(@ruta, DEFAULT, DEFAULT)
WHERE database_name = 'GimnasioDB'
ORDER BY event_time DESC;
GO


-- ------------------------------------------------------------------------
-- PARTE 3 - Integrante 3
-- Carga de datos y vistas para Power BI
-- ------------------------------------------------------------------------

-- 1. Verifica que exista la base
IF DB_ID(N'GimnasioDB') IS NULL
    RAISERROR (N'GimnasioDB no existe. Ejecute primero BDGym.sql (Integrante 1).', 16, 1);
GO

USE GimnasioDB;
GO

SET NOCOUNT ON;

-- 2. Carga de datos de prueba. Si las tablas no existen o ya tienen datos, no hace nada
IF OBJECT_ID(N'socios.Socios', N'U') IS NULL
BEGIN
    RAISERROR (N'Faltan las tablas. Ejecute primero BDGym.sql (Integrante 1).', 16, 1);
    RETURN;
END

IF EXISTS (SELECT 1 FROM socios.Socios)
BEGIN
    PRINT N'La base ya tiene datos: se omite la carga para no duplicar.';
    RETURN;
END

DECLARE @Hoy        date         = CAST(GETDATE() AS date);
DECLARE @Ahora      datetime2(0) = SYSDATETIME();
DECLARE @NumSocios  int          = 15000;
DECLARE @NumClases  int          = 8000;

-- Membresías y entrenadores
INSERT facturacion.Membresias (TipoMembresia, DuracionDias, Costo)
VALUES ('Mensual', 30, 30.00), ('Trimestral', 90, 80.00), ('Anual', 365, 270.00), ('VIP', 30, 50.00);

INSERT operaciones.Entrenadores (NombreCompleto, Especialidad)
SELECT CONCAT(
           CHOOSE(value % 12 + 1, 'Carlos','Maria','Jose','Ana','Luis','Sofia','Miguel','Lucia','Pedro','Carmen','Diego','Valeria'),
           ' ',
           CHOOSE((value / 12) % 12 + 1, 'Hernandez','Garcia','Martinez','Lopez','Gonzalez','Rodriguez','Perez','Sanchez','Ramirez','Flores','Rivera','Cruz')),
       CHOOSE(value % 5 + 1, 'Crossfit', 'Pesas', 'Yoga', 'Spinning', 'Box')
FROM GENERATE_SERIES(1, 20)
ORDER BY value;

-- Socios, registrados en los últimos 3 años
INSERT socios.Socios (Nombre, Apellido, DUI, Telefono, Email, FechaRegistro, Estado)
SELECT CHOOSE(value % 12 + 1, 'Carlos','Maria','Jose','Ana','Luis','Sofia','Miguel','Lucia','Pedro','Carmen','Diego','Valeria'),
       CHOOSE((value / 12) % 12 + 1, 'Hernandez','Garcia','Martinez','Lopez','Gonzalez','Rodriguez','Perez','Sanchez','Ramirez','Flores','Rivera','Cruz'),
       CAST(10000000 + value AS varchar(8)) + '-' + CAST(value % 10 AS varchar(1)),
       '7' + RIGHT('0000000' + CAST((value * 7919) % 10000000 AS varchar(8)), 7),
       'socio' + CAST(value AS varchar(10)) + '@gymmail.com',
       DATEADD(DAY, -((value * 37) % 1095), @Hoy),
       'Activo'
FROM GENERATE_SERIES(1, @NumSocios)
ORDER BY value;

-- Clases, unas 20 por día durante un año
INSERT operaciones.Clases (NombreClase, EntrenadorID, CupoMaximo, Horario)
SELECT CASE t.Ent % 5
            WHEN 0 THEN CHOOSE(g.value % 2 + 1, 'Crossfit Intensivo', 'HIIT')
            WHEN 1 THEN CHOOSE(g.value % 2 + 1, 'Pesas Guiadas', 'Funcional')
            WHEN 2 THEN CHOOSE(g.value % 3 + 1, 'Yoga Flow', 'Pilates', 'Stretching')
            WHEN 3 THEN CHOOSE(g.value % 2 + 1, 'Spinning', 'Spinning Endurance')
            ELSE        CHOOSE(g.value % 2 + 1, 'Box Fitness', 'Kickboxing')
       END,
       t.Ent,
       20 + (g.value % 4) * 5,
       DATEADD(HOUR, 6 + (g.value % 14), CAST(DATEADD(DAY, -365 + (g.value / 20), @Hoy) AS datetime2(0)))
FROM GENERATE_SERIES(1, @NumClases) AS g
CROSS APPLY (SELECT (g.value % 20) + 1 AS Ent) AS t
ORDER BY g.value;

-- Reservas: 20 por clase. El trigger de cupo se apaga durante la carga y después se vuelve a encender
DISABLE TRIGGER operaciones.TR_Reservas_ValidarCupo ON operaciones.Reservas;

DECLARE @cDesde int = (SELECT MIN(ClaseID) FROM operaciones.Clases);
DECLARE @cMax    int = (SELECT MAX(ClaseID) FROM operaciones.Clases);
WHILE @cDesde <= @cMax
BEGIN
INSERT operaciones.Reservas (SocioID, ClaseID, FechaReserva, Asistencia)
SELECT ((c.ClaseID * 13 + k.value * 1237) % @NumSocios) + 1,
       c.ClaseID,
       DATEADD(DAY, -((c.ClaseID + k.value) % 7 + 1), c.Horario),
       CASE WHEN c.Horario >= @Ahora THEN 0
            WHEN (c.ClaseID + k.value) % (6 + (c.ClaseID % 20) % 7) = 0 THEN 0
            ELSE 1 END
FROM operaciones.Clases c
CROSS JOIN GENERATE_SERIES(1, 20) AS k
WHERE c.ClaseID BETWEEN @cDesde AND @cDesde + 499;

SET @cDesde += 500;
RAISERROR (N'Reservas cargadas hasta la clase %d de %d', 0, 1, @cDesde, @cMax) WITH NOWAIT;
END;

ENABLE TRIGGER operaciones.TR_Reservas_ValidarCupo ON operaciones.Reservas;

-- Revisa que ninguna clase haya pasado su cupo
IF EXISTS (SELECT 1 FROM operaciones.Reservas r JOIN operaciones.Clases c ON c.ClaseID = r.ClaseID
           GROUP BY c.ClaseID, c.CupoMaximo HAVING COUNT(*) > c.CupoMaximo)
    RAISERROR (N'Hay clases con mas reservas que su cupo.', 16, 1);

-- Pagos: uno por cada ciclo de membresía. El trigger de la bitácora se apaga durante la carga
DISABLE TRIGGER facturacion.TR_Audit_Pagos ON facturacion.Pagos;

DECLARE @sDesde int = (SELECT MIN(SocioID) FROM socios.Socios);
DECLARE @sMax    int = (SELECT MAX(SocioID) FROM socios.Socios);
WHILE @sDesde <= @sMax
BEGIN
INSERT facturacion.Pagos (SocioID, MembresiaID, Monto, MetodoPago, FechaPago)
SELECT s.SocioID,
       m.MembresiaID,
       m.Costo,
       CHOOSE((s.SocioID + k.value) % 3 + 1, 'Efectivo', 'Tarjeta', 'Transferencia'),
       p.FechaPago
FROM socios.Socios s
JOIN facturacion.Membresias m
  ON m.TipoMembresia = CASE WHEN s.SocioID % 10 <= 5 THEN 'Mensual'
                            WHEN s.SocioID % 10 <= 7 THEN 'Trimestral'
                            WHEN s.SocioID % 10 = 8  THEN 'Anual'
                            ELSE 'VIP' END
CROSS JOIN GENERATE_SERIES(0, 35) AS k
CROSS APPLY (SELECT DATEADD(DAY,
                            (s.SocioID * 3 + k.value * 5) % 8
                            + CASE WHEN s.SocioID % 4 = 0 AND k.value >= 2 + s.SocioID % 6 THEN 40 ELSE 0 END,
                            DATEADD(MONTH,
                                    k.value * CASE m.TipoMembresia WHEN 'Trimestral' THEN 3 WHEN 'Anual' THEN 12 ELSE 1 END,
                                    CAST(s.FechaRegistro AS datetime2(0)))) AS FechaPago) AS p
WHERE s.SocioID BETWEEN @sDesde AND @sDesde + 999
  AND p.FechaPago <= @Ahora;

SET @sDesde += 1000;
RAISERROR (N'Pagos cargados hasta el socio %d de %d', 0, 1, @sDesde, @sMax) WITH NOWAIT;
END;

DECLARE @TotalPagos int = (SELECT COUNT(*) FROM facturacion.Pagos);

ENABLE TRIGGER facturacion.TR_Audit_Pagos ON facturacion.Pagos;

-- Deja un solo registro de la carga en la bitácora
INSERT seguridad.AuditoriaLog (Usuario, Accion, Detalle)
VALUES (SUSER_SNAME(), 'CARGA MASIVA',
        CONCAT(N'Carga inicial: ', @NumSocios, N' socios, ', @NumClases, N' clases, ',
               @NumClases * 20, N' reservas y ', @TotalPagos, N' pagos.'));

-- Estado de cada socio según su último pago
DECLARE @eDesde int = (SELECT MIN(SocioID) FROM socios.Socios);
DECLARE @eMax   int = (SELECT MAX(SocioID) FROM socios.Socios);
WHILE @eDesde <= @eMax
BEGIN
    UPDATE s
    SET Estado = CASE
            WHEN u.UltimoPago >= DATEADD(DAY,
                     -(CASE m.TipoMembresia WHEN 'Trimestral' THEN 91 WHEN 'Anual' THEN 365 ELSE 30 END + 15),
                     @Ahora) THEN 'Activo'
            WHEN s.SocioID % 5 = 0 THEN 'Suspendido'
            ELSE 'Inactivo' END
    FROM socios.Socios s
    JOIN (SELECT p.SocioID, MAX(p.FechaPago) AS UltimoPago, MAX(p.MembresiaID) AS MembresiaID
          FROM facturacion.Pagos p
          WHERE p.SocioID BETWEEN @eDesde AND @eDesde + 999
          GROUP BY p.SocioID) u ON u.SocioID = s.SocioID
    JOIN facturacion.Membresias m ON m.MembresiaID = u.MembresiaID
    WHERE s.SocioID BETWEEN @eDesde AND @eDesde + 999;

    SET @eDesde += 1000;
    RAISERROR (N'Estado de socios actualizado hasta el socio %d de %d', 0, 1, @eDesde, @eMax) WITH NOWAIT;
END;

PRINT N'Carga completada.';
GO

-- 3. Cantidad de filas por tabla y rango de fechas cargadas
SELECT s.name AS Esquema, t.name AS Tabla, SUM(ps.row_count) AS Filas
FROM sys.dm_db_partition_stats ps
JOIN sys.tables  t ON t.object_id = ps.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE ps.index_id IN (0, 1)
GROUP BY s.name, t.name
ORDER BY s.name, t.name;
GO

SELECT N'Pagos'    AS Tabla, CAST(MIN(FechaPago) AS date) AS Desde, CAST(MAX(FechaPago) AS date) AS Hasta FROM facturacion.Pagos
UNION ALL
SELECT N'Clases',  CAST(MIN(Horario) AS date), CAST(MAX(Horario) AS date) FROM operaciones.Clases
UNION ALL
SELECT N'Socios',  MIN(FechaRegistro), MAX(FechaRegistro) FROM socios.Socios;
GO

SELECT Estado, COUNT(*) AS Socios FROM socios.Socios GROUP BY Estado ORDER BY Socios DESC;
GO

-- 4. Vistas del esquema reportes que usa Power BI
IF SCHEMA_ID(N'reportes') IS NULL EXEC (N'CREATE SCHEMA reportes AUTHORIZATION dbo');
GO

-- Consulta 1: ingresos por mes, acumulado y variación (SUM OVER, LAG)
CREATE OR ALTER VIEW reportes.vw_Q1_IngresosMensuales
AS
WITH m AS (
    SELECT DATEFROMPARTS(YEAR(FechaPago), MONTH(FechaPago), 1) AS Mes,
           SUM(Monto) AS Ingreso,
           COUNT(*)   AS NumPagos
    FROM facturacion.Pagos
    GROUP BY DATEFROMPARTS(YEAR(FechaPago), MONTH(FechaPago), 1)
)
SELECT Mes, NumPagos, Ingreso,
       SUM(Ingreso) OVER (ORDER BY Mes ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS IngresoAcumulado,
       LAG(Ingreso) OVER (ORDER BY Mes) AS IngresoMesAnterior,
       CAST(100.0 * (Ingreso - LAG(Ingreso) OVER (ORDER BY Mes))
                  / NULLIF(LAG(Ingreso) OVER (ORDER BY Mes), 0) AS decimal(7,2)) AS VariacionPct
FROM m;
GO

-- Consulta 2: ranking de entrenadores por asistencia (RANK, DENSE_RANK)
CREATE OR ALTER VIEW reportes.vw_Q2_RankingEntrenadores
AS
WITH a AS (
    SELECT e.EntrenadorID, e.NombreCompleto AS Entrenador, e.Especialidad,
           COUNT(DISTINCT c.ClaseID) AS Clases,
           COUNT(r.ReservaID)        AS Reservas,
           SUM(CAST(r.Asistencia AS int)) AS Asistentes
    FROM operaciones.Entrenadores e
    JOIN operaciones.Clases    c ON c.EntrenadorID = e.EntrenadorID
    JOIN operaciones.Reservas  r ON r.ClaseID = c.ClaseID
    WHERE c.Horario < SYSDATETIME()
    GROUP BY e.EntrenadorID, e.NombreCompleto, e.Especialidad
)
SELECT EntrenadorID, Entrenador, Especialidad, Clases, Reservas, Asistentes,
       CAST(100.0 * Asistentes / NULLIF(Reservas, 0) AS decimal(5,2)) AS TasaAsistenciaPct,
       RANK()       OVER (ORDER BY Asistentes DESC) AS RankGeneral,
       DENSE_RANK() OVER (PARTITION BY Especialidad ORDER BY Asistentes DESC) AS RankEnEspecialidad,
       CAST(100.0 * Asistentes / SUM(Asistentes) OVER () AS decimal(5,2)) AS PctDelTotal
FROM a;
GO

-- Consulta 3: pagos con más de 15 días de retraso (LAG, ROW_NUMBER, AVG OVER, NTILE)
CREATE OR ALTER VIEW reportes.vw_Q3_PausasEntrePagos
AS
WITH p AS (
    SELECT pg.SocioID, m.TipoMembresia, pg.FechaPago,
           LAG(pg.FechaPago)  OVER (PARTITION BY pg.SocioID ORDER BY pg.FechaPago) AS PagoAnterior,
           ROW_NUMBER()       OVER (PARTITION BY pg.SocioID ORDER BY pg.FechaPago) AS NumPago
    FROM facturacion.Pagos pg
    JOIN facturacion.Membresias m ON m.MembresiaID = pg.MembresiaID
),
g AS (
    SELECT SocioID, TipoMembresia, NumPago, PagoAnterior, FechaPago,
           DATEDIFF(DAY, PagoAnterior, FechaPago) AS DiasEntrePagos,
           CASE TipoMembresia WHEN 'Trimestral' THEN 91 WHEN 'Anual' THEN 365 ELSE 30 END AS DiasCiclo
    FROM p
    WHERE PagoAnterior IS NOT NULL
)
SELECT SocioID, TipoMembresia, NumPago, CAST(PagoAnterior AS date) AS PagoAnterior, CAST(FechaPago AS date) AS FechaPago,
       DiasEntrePagos, DiasCiclo,
       DiasEntrePagos - DiasCiclo AS DiasDeRetraso,
       CAST(AVG(CAST(DiasEntrePagos - DiasCiclo AS decimal(9,2))) OVER (PARTITION BY TipoMembresia) AS decimal(9,2)) AS PromedioRetrasoTipo,
       NTILE(4) OVER (ORDER BY DiasEntrePagos - DiasCiclo DESC) AS Cuartil
FROM g
WHERE DiasEntrePagos - DiasCiclo > 15;
GO

-- Vistas de apoyo para los KPIs y filtros del dashboard
CREATE OR ALTER VIEW reportes.vw_Ingresos
AS
SELECT pg.PagoID,
       CAST(pg.FechaPago AS date) AS Fecha,
       YEAR(pg.FechaPago)  AS Anio,
       MONTH(pg.FechaPago) AS Mes,
       pg.Monto, pg.MetodoPago, m.TipoMembresia, pg.SocioID
FROM facturacion.Pagos pg
JOIN facturacion.Membresias m ON m.MembresiaID = pg.MembresiaID;
GO

CREATE OR ALTER VIEW reportes.vw_OcupacionClases
AS
SELECT c.ClaseID, c.Horario, CAST(c.Horario AS date) AS Fecha,
       c.NombreClase, e.NombreCompleto AS Entrenador, e.Especialidad,
       c.CupoMaximo,
       CASE WHEN c.Horario < SYSDATETIME() THEN 'Finalizada' ELSE 'Programada' END AS EstadoClase,
       ISNULL(r.Reservas, 0)   AS Reservas,
       ISNULL(r.Asistentes, 0) AS Asistentes,
       CAST(100.0 * ISNULL(r.Asistentes, 0) / c.CupoMaximo AS decimal(5,2)) AS PctOcupacion
FROM operaciones.Clases c
JOIN operaciones.Entrenadores e ON e.EntrenadorID = c.EntrenadorID
LEFT JOIN (SELECT ClaseID,
                  COUNT(*) AS Reservas,
                  SUM(CAST(Asistencia AS int)) AS Asistentes
           FROM operaciones.Reservas
           GROUP BY ClaseID) r ON r.ClaseID = c.ClaseID;
GO

CREATE OR ALTER VIEW reportes.vw_Socios
AS
WITH ult AS (
    SELECT p.SocioID, m.TipoMembresia,
           ROW_NUMBER() OVER (PARTITION BY p.SocioID ORDER BY p.FechaPago DESC) AS rn
    FROM facturacion.Pagos p
    JOIN facturacion.Membresias m ON m.MembresiaID = p.MembresiaID
)
SELECT s.SocioID, s.Estado, s.FechaRegistro,
       CASE WHEN DATEDIFF(MONTH, s.FechaRegistro, GETDATE()) < 6  THEN '0-6 meses'
            WHEN DATEDIFF(MONTH, s.FechaRegistro, GETDATE()) < 12 THEN '6-12 meses'
            WHEN DATEDIFF(MONTH, s.FechaRegistro, GETDATE()) < 24 THEN '1-2 anios'
            ELSE 'Mas de 2 anios' END AS Antiguedad,
       u.TipoMembresia AS MembresiaActual
FROM socios.Socios s
LEFT JOIN ult u ON u.SocioID = s.SocioID AND u.rn = 1;
GO

-- Calendario para los filtros de fecha
CREATE OR ALTER VIEW reportes.vw_Calendario
AS
SELECT d.Fecha,
       YEAR(d.Fecha)  AS Anio,
       MONTH(d.Fecha) AS NumMes,
       DATENAME(MONTH, d.Fecha) AS NombreMes,
       DATEFROMPARTS(YEAR(d.Fecha), MONTH(d.Fecha), 1) AS PrimerDiaMes,
       DATEPART(QUARTER, d.Fecha) AS Trimestre
FROM (SELECT DATEADD(DAY, value, CAST('2023-01-01' AS date)) AS Fecha
      FROM GENERATE_SERIES(0, DATEDIFF(DAY, '2023-01-01', '2027-12-31'))) d;
GO

-- Prueba rápida de las tres consultas
SELECT TOP (5) * FROM reportes.vw_Q1_IngresosMensuales ORDER BY Mes DESC;
SELECT TOP (5) * FROM reportes.vw_Q2_RankingEntrenadores ORDER BY RankGeneral;
SELECT TOP (5) * FROM reportes.vw_Q3_PausasEntrePagos ORDER BY DiasDeRetraso DESC;
GO

-- 5. Permiso de lectura para Power BI y prueba con usr_powerbi
GRANT SELECT ON SCHEMA::reportes TO rol_reporteria;
GO

EXECUTE AS USER = N'usr_powerbi';
    SELECT TOP (3) * FROM reportes.vw_Ingresos;
REVERT;
GO


-- ------------------------------------------------------------------------
-- PARTE 2 - Integrante 2
-- Dimensionamiento, índices y consultas analíticas
-- ------------------------------------------------------------------------

USE GimnasioDB;
GO

-- 1. Dimensionamiento: bytes por fila medidos y proyección a 3 años
WITH medido AS (
    SELECT s.name + '.' + t.name AS Tabla,
           SUM(ps.row_count) AS Filas,
           SUM(ps.used_page_count) * 8192.0 AS Bytes
    FROM sys.dm_db_partition_stats ps
    JOIN sys.tables  t ON t.object_id = ps.object_id
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE ps.index_id IN (0, 1)
    GROUP BY s.name, t.name
),
supuesto AS (
    SELECT * FROM (VALUES ('facturacion.Pagos', 140520),
                          ('operaciones.Reservas', 146000),
                          ('socios.Socios', 5000),
                          ('operaciones.Clases', 7300)) AS v (Tabla, NuevasPorAnio)
)
SELECT m.Tabla,
       m.Filas AS FilasHoy,
       m.Filas + 3 * a.NuevasPorAnio AS FilasA3Anios,
       CAST(m.Bytes / m.Filas AS decimal(8,1)) AS BytesPorFila,
       CAST((m.Filas + 3 * a.NuevasPorAnio) * (m.Bytes / m.Filas) / 1048576.0
            AS decimal(10,2)) AS MB_Datos_A3Anios
FROM medido m
JOIN supuesto a ON a.Tabla = m.Tabla
ORDER BY MB_Datos_A3Anios DESC;
GO

-- 2. Quita los índices para poder medir el antes
DROP INDEX IF EXISTS IX_Pagos_FechaPago         ON facturacion.Pagos;
DROP INDEX IF EXISTS IX_Pagos_SocioID_FechaPago ON facturacion.Pagos;
DROP INDEX IF EXISTS IX_Reservas_ClaseID        ON operaciones.Reservas;
DROP INDEX IF EXISTS IX_Clases_Horario          ON operaciones.Clases;
GO

-- 3. Medición antes de los índices: primero las vistas de Power BI y luego las mismas consultas con filtro
CHECKPOINT;
DBCC DROPCLEANBUFFERS;
GO
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO

SELECT * FROM reportes.vw_Q1_IngresosMensuales ORDER BY Mes;
GO

SELECT * FROM reportes.vw_Q2_RankingEntrenadores ORDER BY RankGeneral;
GO

SELECT * FROM reportes.vw_Q3_PausasEntrePagos ORDER BY DiasDeRetraso DESC;
GO

-- Misma lógica de las vistas, filtrada para ver el cambio de Scan a Seek
DECLARE @Desde date = '2026-07-01', @Hasta date = '2026-10-01';
WITH m AS (
    SELECT DATEFROMPARTS(YEAR(FechaPago), MONTH(FechaPago), 1) AS Mes,
           SUM(Monto) AS Ingreso,
           COUNT(*)   AS NumPagos
    FROM facturacion.Pagos
    WHERE FechaPago >= @Desde AND FechaPago < @Hasta
    GROUP BY DATEFROMPARTS(YEAR(FechaPago), MONTH(FechaPago), 1)
)
SELECT Mes, NumPagos, Ingreso,
       SUM(Ingreso) OVER (ORDER BY Mes ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS IngresoAcumulado,
       LAG(Ingreso) OVER (ORDER BY Mes) AS IngresoMesAnterior,
       CAST(100.0 * (Ingreso - LAG(Ingreso) OVER (ORDER BY Mes))
                  / NULLIF(LAG(Ingreso) OVER (ORDER BY Mes), 0) AS decimal(7,2)) AS VariacionPct
FROM m
OPTION (RECOMPILE);
GO

DECLARE @Desde date = '2026-09-01', @Hasta date = '2026-10-01';
WITH a AS (
    SELECT e.EntrenadorID, e.NombreCompleto AS Entrenador, e.Especialidad,
           COUNT(DISTINCT c.ClaseID) AS Clases,
           COUNT(r.ReservaID)        AS Reservas,
           SUM(CAST(r.Asistencia AS int)) AS Asistentes
    FROM operaciones.Entrenadores e
    JOIN operaciones.Clases    c ON c.EntrenadorID = e.EntrenadorID
    JOIN operaciones.Reservas  r ON r.ClaseID = c.ClaseID
    WHERE c.Horario >= @Desde AND c.Horario < @Hasta
      AND c.Horario < SYSDATETIME()
    GROUP BY e.EntrenadorID, e.NombreCompleto, e.Especialidad
)
SELECT EntrenadorID, Entrenador, Especialidad, Clases, Reservas, Asistentes,
       CAST(100.0 * Asistentes / NULLIF(Reservas, 0) AS decimal(5,2)) AS TasaAsistenciaPct,
       RANK()       OVER (ORDER BY Asistentes DESC) AS RankGeneral,
       DENSE_RANK() OVER (PARTITION BY Especialidad ORDER BY Asistentes DESC) AS RankEnEspecialidad,
       CAST(100.0 * Asistentes / SUM(Asistentes) OVER () AS decimal(5,2)) AS PctDelTotal
FROM a
OPTION (RECOMPILE);
GO

DECLARE @SocioDesde int = 1, @SocioHasta int = 500;
WITH p AS (
    SELECT pg.SocioID, m.TipoMembresia, pg.FechaPago,
           LAG(pg.FechaPago)  OVER (PARTITION BY pg.SocioID ORDER BY pg.FechaPago) AS PagoAnterior,
           ROW_NUMBER()       OVER (PARTITION BY pg.SocioID ORDER BY pg.FechaPago) AS NumPago
    FROM facturacion.Pagos pg
    JOIN facturacion.Membresias m ON m.MembresiaID = pg.MembresiaID
    WHERE pg.SocioID BETWEEN @SocioDesde AND @SocioHasta
),
g AS (
    SELECT SocioID, TipoMembresia, NumPago, PagoAnterior, FechaPago,
           DATEDIFF(DAY, PagoAnterior, FechaPago) AS DiasEntrePagos,
           CASE TipoMembresia WHEN 'Trimestral' THEN 91 WHEN 'Anual' THEN 365 ELSE 30 END AS DiasCiclo
    FROM p
    WHERE PagoAnterior IS NOT NULL
)
SELECT SocioID, TipoMembresia, NumPago, CAST(PagoAnterior AS date) AS PagoAnterior, CAST(FechaPago AS date) AS FechaPago,
       DiasEntrePagos, DiasCiclo,
       DiasEntrePagos - DiasCiclo AS DiasDeRetraso,
       CAST(AVG(CAST(DiasEntrePagos - DiasCiclo AS decimal(9,2))) OVER (PARTITION BY TipoMembresia) AS decimal(9,2)) AS PromedioRetrasoTipo,
       NTILE(4) OVER (ORDER BY DiasEntrePagos - DiasCiclo DESC) AS Cuartil
FROM g
WHERE DiasEntrePagos - DiasCiclo > 15
OPTION (RECOMPILE);
GO

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-- 4. Índices non-clustered en FG_Indices
CREATE NONCLUSTERED INDEX IX_Pagos_FechaPago
    ON facturacion.Pagos (FechaPago) INCLUDE (Monto) ON FG_Indices;
CREATE NONCLUSTERED INDEX IX_Pagos_SocioID_FechaPago
    ON facturacion.Pagos (SocioID, FechaPago) INCLUDE (MembresiaID) ON FG_Indices;
CREATE NONCLUSTERED INDEX IX_Reservas_ClaseID
    ON operaciones.Reservas (ClaseID) INCLUDE (Asistencia) ON FG_Indices;
CREATE NONCLUSTERED INDEX IX_Clases_Horario
    ON operaciones.Clases (Horario) INCLUDE (EntrenadorID) ON FG_Indices;
GO

-- Tamaño de los índices creados
SELECT OBJECT_SCHEMA_NAME(i.object_id) + '.' + OBJECT_NAME(i.object_id) AS Tabla,
       i.name AS Indice,
       CAST(SUM(ps.used_page_count) * 8 / 1024.0 AS decimal(10,2)) AS MB
FROM sys.indexes i
JOIN sys.dm_db_partition_stats ps
  ON ps.object_id = i.object_id AND ps.index_id = i.index_id
WHERE i.name LIKE 'IX[_]%'
  AND OBJECT_SCHEMA_NAME(i.object_id) IN ('socios', 'operaciones', 'facturacion')
GROUP BY i.object_id, i.name
ORDER BY MB DESC;
GO

-- 5. Medición después de los índices, con las mismas consultas
CHECKPOINT;
DBCC DROPCLEANBUFFERS;
GO
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO

SELECT * FROM reportes.vw_Q1_IngresosMensuales ORDER BY Mes;
GO

SELECT * FROM reportes.vw_Q2_RankingEntrenadores ORDER BY RankGeneral;
GO

SELECT * FROM reportes.vw_Q3_PausasEntrePagos ORDER BY DiasDeRetraso DESC;
GO

-- Misma lógica de las vistas, filtrada para ver el cambio de Scan a Seek
DECLARE @Desde date = '2026-07-01', @Hasta date = '2026-10-01';
WITH m AS (
    SELECT DATEFROMPARTS(YEAR(FechaPago), MONTH(FechaPago), 1) AS Mes,
           SUM(Monto) AS Ingreso,
           COUNT(*)   AS NumPagos
    FROM facturacion.Pagos
    WHERE FechaPago >= @Desde AND FechaPago < @Hasta
    GROUP BY DATEFROMPARTS(YEAR(FechaPago), MONTH(FechaPago), 1)
)
SELECT Mes, NumPagos, Ingreso,
       SUM(Ingreso) OVER (ORDER BY Mes ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS IngresoAcumulado,
       LAG(Ingreso) OVER (ORDER BY Mes) AS IngresoMesAnterior,
       CAST(100.0 * (Ingreso - LAG(Ingreso) OVER (ORDER BY Mes))
                  / NULLIF(LAG(Ingreso) OVER (ORDER BY Mes), 0) AS decimal(7,2)) AS VariacionPct
FROM m
OPTION (RECOMPILE);
GO

DECLARE @Desde date = '2026-09-01', @Hasta date = '2026-10-01';
WITH a AS (
    SELECT e.EntrenadorID, e.NombreCompleto AS Entrenador, e.Especialidad,
           COUNT(DISTINCT c.ClaseID) AS Clases,
           COUNT(r.ReservaID)        AS Reservas,
           SUM(CAST(r.Asistencia AS int)) AS Asistentes
    FROM operaciones.Entrenadores e
    JOIN operaciones.Clases    c ON c.EntrenadorID = e.EntrenadorID
    JOIN operaciones.Reservas  r ON r.ClaseID = c.ClaseID
    WHERE c.Horario >= @Desde AND c.Horario < @Hasta
      AND c.Horario < SYSDATETIME()
    GROUP BY e.EntrenadorID, e.NombreCompleto, e.Especialidad
)
SELECT EntrenadorID, Entrenador, Especialidad, Clases, Reservas, Asistentes,
       CAST(100.0 * Asistentes / NULLIF(Reservas, 0) AS decimal(5,2)) AS TasaAsistenciaPct,
       RANK()       OVER (ORDER BY Asistentes DESC) AS RankGeneral,
       DENSE_RANK() OVER (PARTITION BY Especialidad ORDER BY Asistentes DESC) AS RankEnEspecialidad,
       CAST(100.0 * Asistentes / SUM(Asistentes) OVER () AS decimal(5,2)) AS PctDelTotal
FROM a
OPTION (RECOMPILE);
GO

DECLARE @SocioDesde int = 1, @SocioHasta int = 500;
WITH p AS (
    SELECT pg.SocioID, m.TipoMembresia, pg.FechaPago,
           LAG(pg.FechaPago)  OVER (PARTITION BY pg.SocioID ORDER BY pg.FechaPago) AS PagoAnterior,
           ROW_NUMBER()       OVER (PARTITION BY pg.SocioID ORDER BY pg.FechaPago) AS NumPago
    FROM facturacion.Pagos pg
    JOIN facturacion.Membresias m ON m.MembresiaID = pg.MembresiaID
    WHERE pg.SocioID BETWEEN @SocioDesde AND @SocioHasta
),
g AS (
    SELECT SocioID, TipoMembresia, NumPago, PagoAnterior, FechaPago,
           DATEDIFF(DAY, PagoAnterior, FechaPago) AS DiasEntrePagos,
           CASE TipoMembresia WHEN 'Trimestral' THEN 91 WHEN 'Anual' THEN 365 ELSE 30 END AS DiasCiclo
    FROM p
    WHERE PagoAnterior IS NOT NULL
)
SELECT SocioID, TipoMembresia, NumPago, CAST(PagoAnterior AS date) AS PagoAnterior, CAST(FechaPago AS date) AS FechaPago,
       DiasEntrePagos, DiasCiclo,
       DiasEntrePagos - DiasCiclo AS DiasDeRetraso,
       CAST(AVG(CAST(DiasEntrePagos - DiasCiclo AS decimal(9,2))) OVER (PARTITION BY TipoMembresia) AS decimal(9,2)) AS PromedioRetrasoTipo,
       NTILE(4) OVER (ORDER BY DiasEntrePagos - DiasCiclo DESC) AS Cuartil
FROM g
WHERE DiasEntrePagos - DiasCiclo > 15
OPTION (RECOMPILE);
GO

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-- 6. Dimensionamiento final: datos + índices y porcentaje que ocupan los índices
WITH base AS (
    SELECT s.name + '.' + t.name AS Tabla,
           SUM(CASE WHEN i.index_id IN (0, 1) THEN ps.row_count END) AS Filas,
           SUM(CASE WHEN i.index_id IN (0, 1) THEN ps.used_page_count ELSE 0 END) * 8192.0 AS BytesDatos,
           SUM(CASE WHEN i.index_id > 1       THEN ps.used_page_count ELSE 0 END) * 8192.0 AS BytesIndices
    FROM sys.tables t
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    JOIN sys.indexes i ON i.object_id = t.object_id
    JOIN sys.dm_db_partition_stats ps
      ON ps.object_id = i.object_id AND ps.index_id = i.index_id
    WHERE s.name IN ('socios', 'operaciones', 'facturacion')
    GROUP BY s.name, t.name
),
supuesto AS (
    SELECT * FROM (VALUES ('facturacion.Pagos', 140520),
                          ('operaciones.Reservas', 146000),
                          ('socios.Socios', 5000),
                          ('operaciones.Clases', 7300)) AS v (Tabla, NuevasPorAnio)
)
SELECT b.Tabla,
       b.Filas AS FilasHoy,
       b.Filas + 3 * ISNULL(a.NuevasPorAnio, 0) AS FilasA3Anios,
       b.BytesDatos   * (b.Filas + 3.0 * ISNULL(a.NuevasPorAnio, 0)) / b.Filas AS BytesDatos3a,
       b.BytesIndices * (b.Filas + 3.0 * ISNULL(a.NuevasPorAnio, 0)) / b.Filas AS BytesIndices3a
INTO #dim
FROM base b
LEFT JOIN supuesto a ON a.Tabla = b.Tabla;

SELECT Tabla, FilasHoy, FilasA3Anios,
       CAST(BytesDatos3a / 1048576.0 AS decimal(10,2))   AS Datos_MB,
       CAST(BytesIndices3a / 1048576.0 AS decimal(10,2)) AS Indices_MB,
       CAST((BytesDatos3a + BytesIndices3a) / 1048576.0 AS decimal(10,2)) AS Total_MB
FROM #dim
ORDER BY Total_MB DESC;

SELECT CAST(SUM(BytesDatos3a) / 1048576.0 AS decimal(10,1))                    AS Datos_MB,
       CAST(SUM(BytesIndices3a) / 1048576.0 AS decimal(10,1))                  AS Indices_MB,
       CAST(SUM(BytesDatos3a + BytesIndices3a) / 1048576.0 AS decimal(10,1))   AS Total_MB,
       CAST(100.0 * SUM(BytesIndices3a) / SUM(BytesDatos3a) AS decimal(5,1))   AS PctIndicesSobreDatos,
       CAST(SUM(BytesDatos3a) * 1.2 / 1048576.0 AS decimal(10,1))              AS TotalGuia_Con20Pct_MB,
       CAST(SUM(BytesDatos3a) * 1.4 / 1048576.0 AS decimal(10,1))              AS TotalGuia_Con40Pct_MB,
       CAST(SUM(BytesDatos3a + BytesIndices3a) * 1.2 / 1048576.0 AS decimal(10,1)) AS TotalReal_Mas20PctMargen_MB
FROM #dim;

DROP TABLE #dim;
GO


-- ------------------------------------------------------------------------
-- PARTE 4 - Integrante 4
-- Jobs de respaldo en SQL Server Agent
-- ------------------------------------------------------------------------

-- 1. Verifica el modelo FULL y la hora del servidor (UTC, 6 horas más que El Salvador)
USE master;
GO

SELECT name AS BaseDeDatos, recovery_model_desc AS ModeloRecuperacion
FROM sys.databases
WHERE name = 'GimnasioDB';
GO

SELECT SYSDATETIME() AS HoraServidor, SYSDATETIMEOFFSET() AS HoraConZona;
GO

-- 2. Jobs de respaldo
USE msdb;
GO

-- Borra los jobs si ya existen
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'GimnasioDB - Backup FULL')
    EXEC msdb.dbo.sp_delete_job @job_name = N'GimnasioDB - Backup FULL', @delete_unused_schedule = 1;
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'GimnasioDB - Backup DIFERENCIAL')
    EXEC msdb.dbo.sp_delete_job @job_name = N'GimnasioDB - Backup DIFERENCIAL', @delete_unused_schedule = 1;
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'GimnasioDB - Backup LOG')
    EXEC msdb.dbo.sp_delete_job @job_name = N'GimnasioDB - Backup LOG', @delete_unused_schedule = 1;
GO

-- Los jobs tienen como dueño a login_respaldo, así se ejecutan con sus permisos y no con sa
-- FULL: lunes a las 3:00 PM (21:00 UTC)
EXEC msdb.dbo.sp_add_job
     @job_name         = N'GimnasioDB - Backup FULL',
     @description      = N'Backup completo semanal, lunes 3:00 PM (21:00 UTC)',
     @owner_login_name = N'login_respaldo';
EXEC msdb.dbo.sp_add_jobstep
     @job_name      = N'GimnasioDB - Backup FULL',
     @step_name     = N'Backup FULL',
     @subsystem     = N'TSQL',
     @database_name = N'master',
     @command       = N'DECLARE @archivo NVARCHAR(400) = N''/backup/GimnasioDB_FULL_'' + FORMAT(SYSDATETIME(), ''yyyyMMdd_HHmmss'') + N''.bak'';
BACKUP DATABASE GimnasioDB TO DISK = @archivo WITH INIT, NAME = N''GimnasioDB - Backup FULL'';';

-- freq_type 8 = semanal, freq_interval 2 = lunes, 210000 = 21:00:00
EXEC msdb.dbo.sp_add_jobschedule
     @job_name               = N'GimnasioDB - Backup FULL',
     @name                   = N'Semanal - Lunes 21:00 UTC',
     @freq_type              = 8,
     @freq_interval          = 2,
     @freq_recurrence_factor = 1,
     @active_start_time      = 210000;
EXEC msdb.dbo.sp_add_jobserver @job_name = N'GimnasioDB - Backup FULL', @server_name = N'(local)';
GO

-- DIFERENCIAL: martes a domingo a las 3:00 PM (21:00 UTC)
EXEC msdb.dbo.sp_add_job
     @job_name         = N'GimnasioDB - Backup DIFERENCIAL',
     @description      = N'Backup diferencial de martes a domingo, 3:00 PM (21:00 UTC)',
     @owner_login_name = N'login_respaldo';
EXEC msdb.dbo.sp_add_jobstep
     @job_name      = N'GimnasioDB - Backup DIFERENCIAL',
     @step_name     = N'Backup DIFERENCIAL',
     @subsystem     = N'TSQL',
     @database_name = N'master',
     @command       = N'DECLARE @archivo NVARCHAR(400) = N''/backup/GimnasioDB_DIFF_'' + FORMAT(SYSDATETIME(), ''yyyyMMdd_HHmmss'') + N''.bak'';
BACKUP DATABASE GimnasioDB TO DISK = @archivo WITH DIFFERENTIAL, INIT, NAME = N''GimnasioDB - Backup DIFERENCIAL'';';

-- 125 es la suma de los días: domingo 1, martes 4, miércoles 8, jueves 16, viernes 32 y sábado 64
EXEC msdb.dbo.sp_add_jobschedule
     @job_name               = N'GimnasioDB - Backup DIFERENCIAL',
     @name                   = N'Martes a domingo 21:00 UTC',
     @freq_type              = 8,
     @freq_interval          = 125,
     @freq_recurrence_factor = 1,
     @active_start_time      = 210000;
EXEC msdb.dbo.sp_add_jobserver @job_name = N'GimnasioDB - Backup DIFERENCIAL', @server_name = N'(local)';
GO

-- LOG: cada 15 minutos, todo el día
EXEC msdb.dbo.sp_add_job
     @job_name         = N'GimnasioDB - Backup LOG',
     @description      = N'Backup del log de transacciones cada 15 minutos',
     @owner_login_name = N'login_respaldo';
EXEC msdb.dbo.sp_add_jobstep
     @job_name      = N'GimnasioDB - Backup LOG',
     @step_name     = N'Backup LOG',
     @subsystem     = N'TSQL',
     @database_name = N'master',
     @command       = N'DECLARE @archivo NVARCHAR(400) = N''/backup/GimnasioDB_LOG_'' + FORMAT(SYSDATETIME(), ''yyyyMMdd_HHmmss'') + N''.trn'';
BACKUP LOG GimnasioDB TO DISK = @archivo WITH INIT, NAME = N''GimnasioDB - Backup LOG'';';

-- freq_type 4 = diario, freq_subday_type 4 = en minutos, cada 15
EXEC msdb.dbo.sp_add_jobschedule
     @job_name             = N'GimnasioDB - Backup LOG',
     @name                 = N'Cada 15 minutos',
     @freq_type            = 4,
     @freq_interval        = 1,
     @freq_subday_type     = 4,
     @freq_subday_interval = 15,
     @active_start_time    = 0,
     @active_end_time      = 235959;
EXEC msdb.dbo.sp_add_jobserver @job_name = N'GimnasioDB - Backup LOG', @server_name = N'(local)';
GO

-- 3. Prueba de los jobs, uno después del otro porque no se puede hacer un FULL y un DIFERENCIAL al mismo tiempo
EXEC msdb.dbo.sp_start_job @job_name = N'GimnasioDB - Backup FULL';
WAITFOR DELAY '00:00:20';
EXEC msdb.dbo.sp_start_job @job_name = N'GimnasioDB - Backup DIFERENCIAL';
WAITFOR DELAY '00:00:20';
EXEC msdb.dbo.sp_start_job @job_name = N'GimnasioDB - Backup LOG';
WAITFOR DELAY '00:00:10';
GO

-- 4. Historial de los jobs
SELECT j.name AS Job,
       SUSER_SNAME(j.owner_sid) AS Owner,
       msdb.dbo.agent_datetime(h.run_date, h.run_time) AS EjecucionUTC,
       CASE h.run_status WHEN 1 THEN 'Exitoso' WHEN 0 THEN 'Fallido'
                         WHEN 3 THEN 'Cancelado' ELSE 'Otro' END AS Estado,
       h.run_duration AS Duracion_HHMMSS,
       h.message AS Mensaje
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE j.name LIKE N'GimnasioDB%' AND h.step_id = 0
ORDER BY h.instance_id DESC;
GO

-- 5. Backups realizados
SELECT b.database_name AS BaseDeDatos,
       CASE b.type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFERENCIAL' WHEN 'L' THEN 'LOG' END AS Tipo,
       b.backup_start_date  AS InicioUTC,
       b.backup_finish_date AS FinUTC,
       CAST(b.backup_size / 1048576.0 AS DECIMAL(10,2)) AS TamanoMB,
       m.physical_device_name AS Archivo
FROM msdb.dbo.backupset b
JOIN msdb.dbo.backupmediafamily m ON m.media_set_id = b.media_set_id
WHERE b.database_name = 'GimnasioDB'
ORDER BY b.backup_start_date DESC;
GO


-- ------------------------------------------------------------------------
-- PARTE 4 - Integrante 4
-- Plan de restauración
-- ------------------------------------------------------------------------

-- 1. Borra la base de prueba si ya existe
USE master;
GO

IF DB_ID('GimnasioDB_Restore') IS NOT NULL
BEGIN
    ALTER DATABASE GimnasioDB_Restore SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE GimnasioDB_Restore;
END
GO

-- 2. Restauración en cadena en una base aparte (GimnasioDB_Restore)
DECLARE @inicio    DATETIME2 = SYSDATETIME();
DECLARE @full      NVARCHAR(400), @fullFecha DATETIME, @fullLSN NUMERIC(25,0);
DECLARE @diff      NVARCHAR(400);
DECLARE @baseLSN   NUMERIC(25,0);
DECLARE @log       NVARCHAR(400);

-- Busca en msdb el último FULL y el DIFERENCIAL que depende de él
SELECT TOP (1) @full = m.physical_device_name, @fullFecha = b.backup_start_date,
               @fullLSN = b.checkpoint_lsn, @baseLSN = b.last_lsn
FROM msdb.dbo.backupset b
JOIN msdb.dbo.backupmediafamily m ON m.media_set_id = b.media_set_id
WHERE b.database_name = 'GimnasioDB' AND b.type = 'D' AND b.is_copy_only = 0
ORDER BY b.backup_finish_date DESC;

SELECT TOP (1) @diff = m.physical_device_name, @baseLSN = b.last_lsn
FROM msdb.dbo.backupset b
JOIN msdb.dbo.backupmediafamily m ON m.media_set_id = b.media_set_id
WHERE b.database_name = 'GimnasioDB' AND b.type = 'I' AND b.differential_base_lsn = @fullLSN
ORDER BY b.backup_finish_date DESC;

-- FULL con WITH MOVE para usar otros nombres de archivo y NORECOVERY para seguir restaurando
PRINT 'Restaurando FULL: ' + @full;
RESTORE DATABASE GimnasioDB_Restore FROM DISK = @full
WITH MOVE 'GimnasioDB_Primary' TO '/var/opt/mssql/data/GimnasioDB_Restore.mdf',
     MOVE 'GimnasioDB_Datos'   TO '/var/opt/mssql/data/GimnasioDB_Restore_Datos.ndf',
     MOVE 'GimnasioDB_Indices' TO '/var/opt/mssql/data/GimnasioDB_Restore_Indices.ndf',
     MOVE 'GimnasioDB_Log'     TO '/var/opt/mssql/data/GimnasioDB_Restore_Log.ldf',
     NORECOVERY;

-- DIFERENCIAL
IF @diff IS NOT NULL
BEGIN
    PRINT 'Restaurando DIFERENCIAL: ' + @diff;
    RESTORE DATABASE GimnasioDB_Restore FROM DISK = @diff WITH NORECOVERY;
END

-- LOG posteriores al diferencial, en orden
DECLARE logs CURSOR LOCAL FAST_FORWARD FOR
    SELECT m.physical_device_name
    FROM msdb.dbo.backupset b
    JOIN msdb.dbo.backupmediafamily m ON m.media_set_id = b.media_set_id
    WHERE b.database_name = 'GimnasioDB' AND b.type = 'L'
      AND b.backup_start_date >= @fullFecha
      AND b.last_lsn > @baseLSN
    ORDER BY b.first_lsn;

OPEN logs;
FETCH NEXT FROM logs INTO @log;
WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT 'Restaurando LOG: ' + @log;
    RESTORE LOG GimnasioDB_Restore FROM DISK = @log WITH NORECOVERY;
    FETCH NEXT FROM logs INTO @log;
END
CLOSE logs;
DEALLOCATE logs;

-- RECOVERY deja la base en línea
RESTORE DATABASE GimnasioDB_Restore WITH RECOVERY;

-- Tiempo total de la restauración
SELECT CAST(DATEDIFF(MILLISECOND, @inicio, SYSDATETIME()) / 1000.0 AS DECIMAL(10,2)) AS TiempoRestauracionSegundos;
GO

-- 3. Compara los registros de la base original y la restaurada
SELECT 'GimnasioDB (original)' AS Base,
       (SELECT COUNT(*) FROM GimnasioDB.socios.Socios)          AS Socios,
       (SELECT COUNT(*) FROM GimnasioDB.facturacion.Pagos)      AS Pagos,
       (SELECT COUNT(*) FROM GimnasioDB.operaciones.Reservas)   AS Reservas
UNION ALL
SELECT 'GimnasioDB_Restore (restaurada)',
       (SELECT COUNT(*) FROM GimnasioDB_Restore.socios.Socios),
       (SELECT COUNT(*) FROM GimnasioDB_Restore.facturacion.Pagos),
       (SELECT COUNT(*) FROM GimnasioDB_Restore.operaciones.Reservas);
GO
