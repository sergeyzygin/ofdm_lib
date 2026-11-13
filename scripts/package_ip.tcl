# extra_src - список дополнительных файлов (.v/.xci), которые нужно
# подтащить из других папок этого репозитория, если IP использует уже
# упакованный самодельный IP (напр. complex_to_mag_sq использует
# complex_mult). -import_files скопирует их внутрь ip_repo/$name, так что
# результат самодостаточен - но при изменении зависимости (complex_mult)
# нужно не забыть переупаковать все IP, которые её используют, иначе
# копия внутри устареет.
proc package_ip {name top part {extra_src {}}} {
    set proj_dir "ip_repo/_pkg_tmp_$name"
    file delete -force $proj_dir
    create_project -force pkg_tmp $proj_dir -part $part

    add_files [glob $name/src/*.v]
    if {[llength [glob -nocomplain $name/src/*.xci]]} {
        add_files [glob $name/src/*.xci]
    }
    foreach f $extra_src {
        add_files $f
    }

    set_property top $top [current_fileset]

    ipx::package_project -root_dir ip_repo/$name -vendor user.org -library user \
        -taxonomy /UserIP -import_files -set_current false -force

    close_project
    file delete -force $proj_dir
}

# --- список IP на упаковку ---
package_ip complex_mult complex_mult xc7z020clg400-1

package_ip complex_to_mag_sq complex_to_mag_sq xc7z020clg400-1 \
    [list complex_mult/src/complex_mult.v complex_mult/src/cmpy_0.xci]

package_ip complex_to_mag complex_to_mag xc7z020clg400-1

# mv_avg использует xpm_fifo_sync напрямую - это XPM-макрос (не LogiCORE),
# Vivado резолвит его сам и при синтезе, и при симуляции без .xci, так что
# extra_src/зависимости не нужны.
package_ip mv_avg mv_avg xc7z020clg400-1

package_ip mv_avg_dual_ch mv_avg_dual_ch xc7z020clg400-1

package_ip fifo_sample_delay fifo_sample_delay xc7z020clg400-1

# detect_sts сшивает complex_to_mag_sq (-> complex_mult -> cmpy_0),
# complex_mult, mv_avg, mv_avg_dual_ch, complex_to_mag и fifo_sample_delay -
# тянем все их исходники, чтобы пакет был самодостаточным.
package_ip detect_sts detect_sts xc7z020clg400-1 \
    [list complex_to_mag_sq/src/complex_to_mag_sq.v \
          complex_mult/src/complex_mult.v \
          complex_mult/src/cmpy_0.xci \
          mv_avg/src/mv_avg.v \
          mv_avg_dual_ch/src/mv_avg_dual_ch.v \
          complex_to_mag/src/complex_to_mag.v \
          fifo_sample_delay/src/fifo_sample_delay.v]

# package_ip other_ip other_ip_top xc7z020clg400-1
