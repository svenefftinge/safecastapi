SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- =============================================================================================
-- ABSTRACT:
-- =============================================================================================
--
-- ios_query.sql: Primary PostgreSQL query to export measurements for the iOS app update.
--
--                This performs the following actions:
--                     1. Change detection
--                     2. Filters out bad data
--                        a. Sanity filtering
--                        b. Blacklists
--                     3. Reprojects EPSG:4326 -> EPSG:3857 (lat/lon to web Mercator pixel x/y)
--                     4. Converts CPM to uSv/h
--                     5. Bins / clusters data points at ~19m resolution
--                     6. Creates temporary X/Y/Z CSV for export
--
--                 The CSV in #6 is converted into a SQLite 3 binary database for client DL
--                 with a later shell script, to provide integrity checks and faster processing.


-- =============================================================================================
-- ATTENTION!!
-- =============================================================================================
-- THIS IS USED BY A PRIMARY PRODUCTION APPLICATION.
-- 
-- MODIFICATION CAN RESULT IN IOS APP DATA UPDATES BEING CORRUPT, INOPERABLE, OR SERVER LOAD
-- THAT BLOCKS OTHER PROCESSES INCLUDING ALL SAFECAST API FUNCTIONS.
--
-- PLEASE COMMUNICATE AND COMMENT ANY CHANGES MADE.



-- =============================================================================================
-- SERVER / PERMISSION REQUIREMENTS
-- =============================================================================================
-- Table "measruements":  SELECT
-- Table "iOSLastUpdate": CREATE, INSERT, UPDATE, DELETE, SELECT
-- Temporary tables:      CREATE, INSERT, UPDATE, DELETE, SELECT
-- File System:           READ, WRITE, CREATE, DELETE (CSV)



-- =============================================================================================
-- SERVER RESOURCE USE:
-- =============================================================================================
-- - Row/table locking:
--   - iOSLastUpdate: minor, no other processes use.
--
-- - Schema locking:
--   - CREATE TABLE iOSLastUpdate (once ever per server)
--   - CREATE TABLE <various #temp tables>
--   - CREATE INDEX <various #temp indices on #temp tables>
--   - DROP TABLE <various #temp tables>
--
-- - Change detection:
--   - While a single-row permanent table is maintained by this script on the server for tracking 
--     changes, it does not require this to function or expect that it necessarily exists.
--   - As of 2014-04-15 change detection is made mostly inoperable by test data submssions.
--
-- - Runtime
--   - As of 2014-04-16 this takes ~7 mins to run on Cloud 66.
--
-- - CPU, I/O
--   - Significant CPU resources are used, but not enough to block other processes.
--   - Several GB in temp tables and VM are required.
--   - Be advised this can increase rapidly if you change this script; subtle changes can
--     create significant server load.



-- =============================================================================================
-- MAINTENANCE REQUIREMENTS:
-- =============================================================================================
-- - Filtering bad data:
--   - If points are not removed from the database, they should be blacklisted by the primary key
--     ID or another indexed integer column.
--   - Blacklists should be avoided if possible.
-- - Dose rate conversion:
--   - Any new device submitting measurements in CPM must have a gamma sensitivity manually hardcoded
--     below due to database schema limitations not including this information.
--   - This should not be done for test devices or devices that do not primarily measure gamma radiation.
--   - Note a device_id of NULL is assumed to be a bGeigie with a LND7317 sensor.




BEGIN TRANSACTION;
     CREATE TABLE IF NOT EXISTS iOSLastExport(LastMaxID INT, ExportDate TIMESTAMP);
COMMIT TRANSACTION;

-- performance note: Temp1 is created with as limited of width data types as possible, for example
--                   32-bit floats and 16-bit date integers.  While the numerics time on the CPU
--                   is not affected, this produces a 2x-5x increase in query performance due to less
--                   disk IO and more efficient composite b-tree indexing.

BEGIN TRANSACTION;
     CREATE TEMPORARY TABLE IF NOT EXISTS Temp1(X1 INT, Y1 INT, captured_at INT2, DRE FLOAT4);
     TRUNCATE TABLE Temp1;
COMMIT TRANSACTION;

-- ======================================================
-- COORDINATE SYSTEM REPROJECTION
-- ======================================================
-- Coordinate system reprojection and magic numbers are derived from:
--      http://msdn.microsoft.com/en-us/library/bb259689.aspx
--
--      These values are specific to Web Mercator EPSG 3857 zoom level 13.
--      For other zoom levels you must change these values.
--
--      Reprojection "magic numbers" are hardcoded into
--      the main query with collapsed expressions and
--      reciprocal estimates for performance.
--
--      DO NOT CHANGE THE ZOOM LEVEL ON THE PRODUCTION IOS APP.


-- ======================================================
-- GAMMA SENSITIVITY REFERENCE INFORMATION
-- ======================================================
-- This reflects information hardcoded below in the SELECT statements.
-- 
-- CPM is multiplied by the reciprocal estimate, instead of dividing.
-- This provides a minor performance gain.
--
--         device_id  uSvh=CPM/x      Reciprocal Estimate
-- =================  ==========     ====================
--              NULL       350.0       0.0028571428571429
--  5,15,16,17,18,22       350.0       0.0028571428571429
--      6,7,11,13,23       100.0                     0.01
--   4,9,10,12,19,24       132.0       0.0075757575757576
--                21      1750.0    0.0005714285714285714




-- ==============================================================================================================
-- PRIMARY DATA QUERY
-- ==============================================================================================================

-- **** TEST: JP POST MOVED TO MAIN QUERY VIA CASE ****     -- first insert is for NON Japan Post (ie, normal) data
-- uSv/h upper limit 75 -> 5 to correct for users submitting web measurements in CPM

-- Blacklists now specific to area and value to reduce collateral damage.

-- User Blacklists/Filtering       Details
-- =========================       ===========================================================================
-- - user_id = 345 (QuartaRad)   - All data (user submitted only bad data)
-- **** TEST: JP POST MOVED TO MAIN QUERY VIA CASE **** -- - user_id = 347 (JP Post)     - Not blacklisted, just in separate query below to avoid ugly case branching
-- - user_id = 366 (Brain Jones) - Aircraft flight.  Filter:   .au extent only, > 0.30 uSv/h only.
-- - user_id =   9 (Rob)         - Test data.        Filter: Tokyo extent only, > 0.10 uSv/h only.
-- - user_id = 442 (?)           - Test data.        Filter: Tokyo extent only, > 0.10 uSv/h only.

--    user_id=366 check: https://api.safecast.org/en-US/measurements?utf8=%E2%9C%93&latitude=-26.9918&longitude=137.3043&distance=10000&captured_after=&captured_before=&since=&until=&commit=Filter

BEGIN TRANSACTION;

INSERT INTO Temp1(X1, Y1, captured_at, DRE)
SELECT CAST( 
              (ST_X(location::geometry) + 180.0) * 5825.422222222222 + 0.5 
            AS INT
           )
       + (CASE WHEN (user_id = 347) THEN 2 ELSE 0 END) -- JP Post: correct offset to centroid vs. WGS84 trunc
       AS X1
    ,CAST(
            (0.5 - LN(  (1.0 + SIN(ST_Y(location::geometry) * 0.0174532925199433))
                      / (1.0 - SIN(ST_Y(location::geometry) * 0.0174532925199433)))
                   * 0.0795774715459477
            ) * 2097152.0 + 0.5 
          AS INT
         )
     + (CASE WHEN (user_id = 347) THEN -2 ELSE 0 END) -- JP Post: correct offset to centroid vs. WGS84 trunc
     AS Y1
    ,CAST( 
            EXTRACT(epoch FROM captured_at) / 86400 
          AS INT2
         )
     + (CASE WHEN (user_id = 347) THEN -730 ELSE 0 END) -- JP Post: penalty during binning due to low spatial rez
     AS captured_at
    ,CASE
        WHEN unit='cpm' AND device_id IS NULL               THEN value * 0.0028571428571429
        WHEN unit IN ('microsievert','usv')                 THEN value
        WHEN unit='cpm' AND device_id IN (5,15,16,17,18,22) THEN value * 0.0028571428571429
        WHEN unit='cpm' AND device_id IN (6,7,11,13,23)     THEN value * 0.01
        WHEN unit='cpm' AND device_id IN (4,9,10,12,19,24)  THEN value * 0.0075757575757576
        WHEN unit='cpm' AND device_id IN (21)               THEN value * 0.0005714285714285714
        ELSE 0.0
    END 
    AS DRE
FROM measurements
WHERE (SELECT MAX(id) FROM measurements) > COALESCE((SELECT MAX(LastMaxID) FROM iOSLastExport),0)
    AND id NOT BETWEEN 23181608 AND 23182462 -- 100% bad
    AND id NOT BETWEEN 20798302 AND 20803607 -- 20% bad, but better filtering too slow
    AND id NOT BETWEEN 21977826 AND 21979768 -- 100% bad
    AND id NOT BETWEEN 24060795 AND 24067649 -- invalidated, raining, most 2x normal
    AND id NOT IN (13194822,15768545,15768817,15690104,15768346,15768782,15768792,16381794,18001818,17342620,14669786,25389168,25389158,25389157,25389153,24482487,16537265,16537266,19554057,19554058,19554059,19554060,19555677,19589301,19589302,19589303,19589304,19589305,19589303,19589304,19589305,19600634,19699406,17461603,17461607,17461611,17461615,16981355,16240105,16240101,16240097,16240093,16241392,16241388,18001769,25702033,25702031)
    AND id NOT IN (14764408,14764409,14764410,14764411,14764412,14764413,13872611,13872612,14764388,14764389,14764390,14764391,14764392,14764393,14764394,14764395,14764396,14764397,14764398,14764399,14764400,14764401,14764402,14764403,14764404,14764405,14764406,14764407) -- bad streak in hot area
    AND user_id NOT IN (345)--347
    --AND captured_at BETWEEEN TIMESTAMP '2011-03-01 00:00:00' AND localtimestamp + interval '48 hours'
    AND captured_at > TIMESTAMP '2011-03-01 00:00:00'
    AND captured_at < localtimestamp + interval '48 hours'
    AND captured_at IS NOT NULL
    AND value       IS NOT NULL
    AND location    IS NOT NULL
    AND (   (unit  = 'cpm' AND (   (device_id IS NULL AND value BETWEEN 10.0 AND 350000.0) 
                                OR (device_id <=   24 AND value BETWEEN 10.0 AND  30000.0)))
         OR (unit IN ('microsievert','usv')           AND value BETWEEN 0.02 AND      5.0))
    AND (   ST_X(location::geometry) != 0.0
         OR ST_Y(location::geometry) != 0.0)
    AND ST_Y(location::geometry) BETWEEN  -85.05 AND  85.05
    AND ST_X(location::geometry) BETWEEN -180.00 AND 180.00
    AND (   user_id NOT IN (9,442)                                      -- "friendly" ban, specific to area and measurement value
         OR value        < 35.0                                         -- 0.10 uSv/h
         OR ST_Y(location::geometry) NOT BETWEEN  35.4489 AND  35.7278  -- not in tokyo extent
         OR ST_X(location::geometry) NOT BETWEEN 139.5706 AND 139.9186)
    AND (   user_id != 366                                              -- "friendly" ban, specific to area and measurement value
         OR value    <  35.0                                            -- 0.10 uSv/h
         OR ST_Y(location::geometry) NOT BETWEEN -45.5201 AND  -7.6228  -- not in .au extent
         OR ST_X(location::geometry) NOT BETWEEN 111.3241 AND 153.8620
         OR (value < 105.0 AND ST_X(location::geometry) < 111.3241)   );-- western .au coast only - slightly higher max

COMMIT TRANSACTION;

-- TEST: disable 2nd query for JP Post, incorporated into CASE above

-- ==============================================================================================================
-- JAPAN POST WORKAORUND SELECT
-- ==============================================================================================================
-- This 2nd insert is a hack workaround for JP post data
-- it partially corrects the spatial error by approximating the centroid from the original trunc in the firmware
-- -10k to the "days since 1970" is approx a -30 year penalty to the date restrictive binning so as not to
--       contaminate measurements with superior spatial resolution



--BEGIN TRANSACTION;
--INSERT INTO Temp1(X1, Y1, captured_at, DRE)
--SELECT CAST((ST_X(location::geometry)+180.0)*5825.422222222222+0.5 AS INT)+2 AS X1
--    ,CAST((0.5-LN((1.0+SIN(ST_Y(location::geometry)*0.0174532925199433))/(1.0-SIN(ST_Y(location::geometry)*0.0174532925199433)))*0.0795774715459477)*2097152.0+0.5 AS INT)-2 AS Y1
--    ,CAST(EXTRACT(epoch FROM captured_at)/86400 AS INT2)-10950 AS captured_at
--    ,CASE
--        WHEN unit='cpm' AND device_id IS NULL               THEN value * 0.0028571428571429
--        WHEN unit IN ('microsievert','usv')                 THEN value
--        WHEN unit='cpm' AND device_id IN (5,15,16,17,18,22) THEN value * 0.0028571428571429
--        WHEN unit='cpm' AND device_id IN (6,7,11,13,23)     THEN value * 0.01
--        WHEN unit='cpm' AND device_id IN (4,9,10,12,19,24)  THEN value * 0.0075757575757576
--        WHEN unit='cpm' AND device_id IN (21)               THEN value * 0.0005714285714285714
--        ELSE 0.0
--    END AS DRE
--FROM measurements
--WHERE (SELECT COUNT(*) FROM Temp1) > 0 -- in case new rows get added to measurements between insert blocks
--    AND (SELECT MAX(id) FROM measurements) > COALESCE((SELECT MAX(LastMaxID) FROM iOSLastExport),0)
--    AND user_id = 347
--    AND captured_at > TIMESTAMP '2011-03-01 00:00:00'
--    AND captured_at < localtimestamp + interval '48 hours'
--    AND captured_at IS NOT NULL
--    AND (  (unit='cpm' AND value IS NOT NULL AND value > 10.0 AND ( (device_id IS NULL AND value < 350000.0) OR (device_id <= 24 AND value < 30000.0) ))
--        OR (unit IN ('microsievert','usv') AND value IS NOT NULL AND value > 0.02 AND value < 5.0))
--    AND location IS NOT NULL
--    AND (  ST_X(location::geometry) != 0.0
--        OR ST_Y(location::geometry) != 0.0)
--    AND ST_Y(location::geometry) < 85.05
--    AND ST_Y(location::geometry) > -85.05
--   AND ST_X(location::geometry) >= -180.0
--    AND ST_X(location::geometry) <=  180.0;
--COMMIT TRANSACTION;


BEGIN TRANSACTION;
     CREATE INDEX idx_Temp1_X1Y1CD ON Temp1(X1,Y1,captured_at);
COMMIT TRANSACTION;

-- clamp to bounds of projection (shouldn't ever be hit, but...)
BEGIN TRANSACTION;
     UPDATE Temp1 SET X1 =       0 WHERE X1 <       0;
     UPDATE Temp1 SET X1 = 2097151 WHERE X1 > 2097151;
     UPDATE Temp1 SET Y1 =       0 WHERE Y1 <       0;
     UPDATE Temp1 SET Y1 = 2097151 WHERE Y1 > 2097151;
COMMIT TRANSACTION;

-- ==============================================================================================================
-- POINT GRIDDING / AGGREGATION / BINNING
-- ==============================================================================================================
-- This clusters the data points into a 19m grid simply by (efficient) virtue of integer truncation.
--
-- Spatial indexing and/or OGC geometry/geography types are not necessary for this.
--
-- Date/Time Column:
-- - "T" column: this is "days since 1970".
-- - It is used to select only the latest 270 days of measurements for any given point.
-- - This helps present a more "recent" view of data without culling massive amounts in a crude WHERE.
-- - 270 days is completely arbitrary.
--
-- Performance Advisory:
--   - The indexing in gridding so many millions of points is extremely sensitive to data type widths.
--   - Using 64-bit types for these columns will make this at least an order of magtniude slower.
--   - You have been warned.

BEGIN TRANSACTION;

     CREATE TEMPORARY TABLE IF NOT EXISTS Temp2(X INT,Y INT,T INT2,Z FLOAT4);

     TRUNCATE TABLE Temp2;

     INSERT INTO Temp2(X,Y,T) 
     SELECT X1
           ,Y1
           ,MAX(captured_at) - 270 
     FROM Temp1 
     GROUP BY X1,Y1;

COMMIT TRANSACTION;



BEGIN TRANSACTION;

     UPDATE Temp2 SET Z = (SELECT AVG(DRE) FROM Temp1 WHERE X1=X AND Y1=Y AND captured_at > T);
     
     DROP TABLE Temp1;

COMMIT TRANSACTION;

-- old ORDER BY: ORDER BY Y/256*8192+X/256

-- ==============================================================================================================
-- BINARY DATA STRUCTURE CLUSTERING
-- ==============================================================================================================
-- The very long and very ugly hardcoded ORDER BY is a good thing.
-- 
-- Modeled after Microsoft's "QuadKey", this is a SQL implementation that clusters and orders data such that all
-- pixels for a tile will be contiguous.
--
-- By "recursive", it means that if processing and tiling is done synchronously, the entire process can use
-- aligned, sequential binary reads for maximum IO throughput and low CPU overhead.
-- 
-- This is why the iOS app can rasterize data in 2 minutes while gdal_rastersize takes over 24 hours for the
-- exact same dataset.
--
-- It is like the difference between Doom and povray.
-- It is the only reason the iOS app can update data at all.
-- 
-- iOS app 1.6.9 depends on recursive clustering; that is, it uses direct reads in row-order at each pyramid level.

-- iOS app 1.7.0+ only absolutely depends on z=13 being clustered, however recursive clustering still likely
-- is of benefit to performance nonetheless.  The change is 1.7.0+ uses asynchronous multithreaded
-- processing while tiling and thus must sort/cluster on its end.  This is somewhat slower, but offset by the
-- multithreaded performance.
--
-- ==============================================================================================================
-- MOAR INFO:
-- ==============================================================================================================
--
-- The underlying math is as follows:
--   ORDER BY ((Y>>20)<<1)+(X>>20) ... , ... ((Y>>8)<<13)+(X>>8)
--
-- These bitshift expressions are a collapsed form of the following:
--
--            [A]  [B]  [C]     [A]  [B]
--            === ====  ===     === ====
-- Z= 1:    Y/256/4096*   2 + X/256/4096,
-- Z= 2:    Y/256/2048*   4 + X/256/2048,
-- Z= 3:    Y/256/1024*   8 + X/256/1024,
-- Z= 4:    Y/256/ 512*  16 + X/256/ 512,
-- Z= 5:    Y/256/ 256*  32 + X/256/ 256,
-- Z= 6:    Y/256/ 128*  64 + X/256/ 128,
-- Z= 7:    Y/256/  64* 128 + X/256/  64,
-- Z= 8:    Y/256/  32* 256 + X/256/  32,
-- Z= 9:    Y/256/  16* 512 + X/256/  16,
-- Z=10:    Y/256/   8*1024 + X/256/   8,
-- Z=11:    Y/256/   4*2048 + X/256/   4,
-- Z=12:    Y/256/   2*4096 + X/256/   2,
-- Z=13:    Y/256     *8192 + X/256
--          ---------------   ----------
--           [Y-axis index]   [X-axis index]
-- 
-- What is going on here:
-- 1. [A]: Pixel X/Y is converted to tile X/Y, by dividing the pixel X/Y by 256 (as each tile is 256x256 pixels)
-- 2. [B]: The number of tiles spanning the world, width or height, is then converted to a previous zoom level for clustering.
--         i.   Zoom level 13 has 8192 tiles width or height.  (2^13)
--         ii.  Zoom level  1 has    2 tiles width or height.  (2^ 1)
--         iii. Thus, scaling is /x, where x is 2^(Zsrc-Zdest).
--         iv.  Above, that is /x, where x = 2^(13-1), or /(2^12), or /4096.
-- 3. [C]: The X/Y coordinates are converted to a single tile index by using row ordering, similar to how pixels in a monochrome image
--         are accessed and addressed.
--
-- In summary, the core principles:
-- 1. Use normal, traditional image pixel addressing conventions to reference each tile at a particular zoom level with unique single integer index.
--     - eg: "imageBuffer[y * numRows + x] = 255;"
-- 2. To make this recursive, scale to each zoom level from 1 to the actual resolution, in ascending order.

\copy (SELECT X,Y,CAST(Z*1000.0 AS INT) FROM Temp2 ORDER BY ((Y>>20)<<1)+(X>>20),((Y>>19)<<2)+(X>>19),((Y>>18)<<3)+(X>>18),((Y>>17)<<4)+(X>>17),((Y>>16)<<5)+(X>>16),((Y>>15)<<6)+(X>>15),((Y>>14)<<7)+(X>>14),((Y>>13)<<8)+(X>>13),((Y>>12)<<9)+(X>>12),((Y>>11)<<10)+(X>>11),((Y>>10)<<11)+(X>>10),((Y>>9)<<12)+(X>>9),((Y>>8)<<13)+(X>>8)) to '/tmp/ios13_32.csv' csv


BEGIN TRANSACTION;

     DELETE FROM iOSLastExport 
     WHERE    (SELECT COUNT(*) FROM Temp2) > 0 -- in case rows got added partway through
          AND LastMaxID                    < (SELECT MAX(id) FROM measurements);

     INSERT INTO iOSLastExport(LastMaxID,ExportDate) 
     SELECT MAX(id), CURRENT_TIMESTAMP 
     FROM measurements
     WHERE   (SELECT COUNT(*) FROM Temp2)        > 0
         AND (SELECT  MAX(id) FROM measurements) > COALESCE((SELECT MAX(LastMaxID) FROM iOSLastExport),0);

     DELETE FROM iOSLastExport 
     WHERE   LastMaxID IS NULL 
          OR LastMaxID  = 0;

COMMIT TRANSACTION;



BEGIN TRANSACTION;

     DROP TABLE Temp2;

COMMIT TRANSACTION;
