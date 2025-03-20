print_hash() {
    count="$1"  # Tidak menggunakan 'local' karena tidak semua shell mendukungnya
    i=1
    while [ "$i" -le "$count" ]; do
        printf "#"
        sleep 0.05
        i=$((i + 1))
    done
    echo  # Baris baru setelah mencetak karakter #
}
